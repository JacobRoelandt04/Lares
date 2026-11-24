#!/usr/bin/env bash
# The snapshot installer, the uninstaller, the hook wrapper, the pacman hooks and the polkit files, proven WITHOUT root
# (tools/snapshot/root/, docs/contracts/snapshots.md): install.sh and uninstall.sh run AS THEY ARE on a FAKE ROOT (a temp dir standing
# in for /, their path variables and every /etc /usr /run /var path moved into it, `id` saying root, pacman / install / rm stubs that log),
# the wrapper runs against stub tools, the polkit rule is evaluated with node.
#
#   tools/dev/snapshot_install_probe.sh              last line: SNAPSHOT_INSTALL RESULT PASS|FAIL (exit status follows)
#   ARM=<name> tools/dev/snapshot_install_probe.sh   a fault in a COPY of the files; the run must end FAIL on the arm's own check
#   ARM=all tools/dev/snapshot_install_probe.sh      every ARM; SNAPSHOT_INSTALL ARMS PASS when each failed as it must
#
#   hookfirst   the hooks are installed before the repository is made   -> `order.hooks.last` FAILS
#   nodrain    the wrapper leaves the package names unread              -> `wrapper.reads.every.target` FAILS
#   crashblocks the wrapper passes a crashed tool's status on           -> `wrapper.crash.lets.pacman.go` FAILS
#   norule      the polkit rule does not name the user                  -> `polkit.rule` FAILS
#   deletefree  the rule lets the user delete without a password        -> `polkit.rule` FAILS
#   noetclares  /etc/lares is not made                                  -> `install.etc.lares` FAILS
#   etcleft     the uninstaller leaves an empty /etc/lares              -> `uninstall.removes.everything` FAILS
#   hookslate   the uninstaller removes the hooks after the tool        -> `uninstall.hooks.first` FAILS
#   rmstate     the uninstaller deletes the snapshots                   -> `uninstall.keeps.snapshots` FAILS
#   realpath    an install line that names a real /etc path            -> `install.sh.paths.all.in.the.fake.root` FAILS
#
# It never runs anything as root, never touches /etc, /usr/local or the real pacman, and starts no quickshell.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SNAPSHOT_INSTALL
SNAPSRC=$PWD/tools/snapshot

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in "nodrain wrapper.reads.every.target" "hookfirst order.hooks.last" "crashblocks wrapper.crash.lets.pacman.go" "norule polkit.rule" "deletefree polkit.rule" \
             "noetclares install.etc.lares" "etcleft uninstall.removes.everything" "hookslate uninstall.hooks.first" "rmstate uninstall.keeps.snapshots" "realpath install.sh.paths.all.in.the.fake.root"; do
        arm=${a% *}; chk=${a#* }
        res=$(ARM=$arm bash "$0" 2>&1)
        if printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $arm: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -qF "SIP $chk FAIL"; then echo "  ARM $arm: failed, but not on its own check ($chk)"; bad=1
        else echo "  ARM $arm: failed as it must ($chk)"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
ARM=${ARM:-}

SB=${SANDBOX:-/tmp/lares-sbx-snap-a}
mkdir -p "$SB" || exit 1
W=$(mktemp -d "$SB/sip.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
fail=0
check() {   # check <name> <command...>
    local n=$1; shift
    if "$@" > "$W/last.out" 2>&1; then echo "SIP $n PASS"; return 0; fi
    echo "SIP $n FAIL  $(head -c 400 "$W/last.out" | tr '\n' ' ')"; fail=1; return 1
}

# ---- a COPY of the files (the arms patch the copy, never the tree) ------------------------------------------------------------------
mkdir -p "$W/tools"; cp -a tools/snapshot tools/lib "$W/tools/"; find "$W/tools" -name __pycache__ -prune -exec rm -rf {} +
SRC=$W/tools/snapshot/root
mkdir -p "$SRC/rescue"
# stream B's installer is not here yet: a stand-in that records WHEN it ran (the real one is called by name from the same place)
cat > "$SRC/rescue/install-rescue.sh" <<'EOF'
#!/bin/sh
echo "rescue-install hooks=$(ls "$FR/etc/pacman.d/hooks" 2>/dev/null | tr '\n' ' ')" >> "$CALLS"
EOF
cat > "$SRC/rescue/uninstall-rescue.sh" <<'EOF'
#!/bin/sh
echo "rescue-uninstall hooks=$(ls "$FR/etc/pacman.d/hooks" 2>/dev/null | tr '\n' ' ')" >> "$CALLS"
EOF
patch_file() {   # patch_file <file> <anchor> <replacement>
    PF=$1 ANCHOR=$2 REPL=$3 python3 -B - <<'PY' || { echo "ARM $ARM: anchor missing"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import os, sys
p = os.environ["PF"]; s = open(p).read(); a = os.environ["ANCHOR"]
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, os.environ["REPL"]))
PY
}
case $ARM in
    '') ;;
    hookfirst) patch_file "$SRC/install.sh" '"$PYTHON" -I "$LIB/lares-snapshot-root" init' 'install -m 0644 "$HERE/00-lares-snapshot.hook" "$HOOKDIR/00-lares-snapshot.hook"
"$PYTHON" -I "$LIB/lares-snapshot-root" init' ;;
    nodrain) patch_file "$SRC/hook" '[ -t 0 ] || TARGETS=$(cat)' ':' ;;
    crashblocks) patch_file "$SRC/hook" '    *) skip tool' '    *) exit "$rc" ;;
    9) skip tool' ;;
    norule) patch_file "$SRC/50-lares-snapshot.rules.in" 'subject.user != "@USER@"' 'subject.user != ""' ;;
    deletefree) patch_file "$SRC/50-lares-snapshot.rules.in" 'action.id == "org.lares.snapshot.keep")' 'action.id == "org.lares.snapshot.keep" || action.id == "org.lares.snapshot.delete")' ;;
    noetclares) patch_file "$SRC/install.sh" 'install -d -m 0755 -o root -g root "$LIB" "$ETCLARES"' 'install -d -m 0755 -o root -g root "$LIB"' ;;
    etcleft) patch_file "$SRC/uninstall.sh" 'rmdir "$ETCLARES" 2> /dev/null || true      # only while empty: a snapshot.off in it stays' ':' ;;
    hookslate) patch_file "$SRC/uninstall.sh" 'rm -f "$HOOKDIR/00-lares-snapshot.hook" "$HOOKDIR/zz-lares-snapshot-done.hook"' ':'
               patch_file "$SRC/uninstall.sh" 'rmdir /usr/local/lib/lares' 'rm -f "$HOOKDIR/00-lares-snapshot.hook" "$HOOKDIR/zz-lares-snapshot-done.hook"
rmdir /usr/local/lib/lares' ;;
    rmstate) patch_file "$SRC/uninstall.sh" 'rm -rf "$LIB"' 'rm -rf "$LIB" "$STATE"' ;;
    realpath) patch_file "$SRC/install.sh" 'install -d -m 0755 -o root -g root "$LIB"' 'touch	/etc/lares-snapshot-arm
install -d -m 0755 -o root -g root "$LIB"' ;;
    *) echo "unknown ARM $ARM"; exit 2 ;;
esac

# ==================================================== static: the files parse ========================================================
check syntax.sh bash -c 'for f in install.sh uninstall.sh hook; do bash -n "$1/$f" || exit 1; done; sh -n "$1/hook"' _ "$SNAPSRC/root"
check syntax.python python3 -B -c '
import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f).read(), f)' "$SNAPSRC/root/lares-snapshot-root" "$SNAPSRC/root/snaprules.py" "$SNAPSRC/lares-snapshot"
check policy.xml python3 -B -c '
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]); ids = sorted(a.get("id") for a in t.getroot().iter("action"))
assert ids == ["org.lares.snapshot.create", "org.lares.snapshot.delete", "org.lares.snapshot.keep"], ids
for a in t.getroot().iter("action"):
    assert a.find("defaults/allow_active") is not None and a.find("defaults/allow_any").text == "auth_admin"
    ann = {n.get("key"): n.text for n in a.iter("annotate")}
    # pkexec picks the action by the tool AND its first argument
    assert ann == {"org.freedesktop.policykit.exec.path": "/usr/local/lib/lares/snapshot/lares-snapshot-root",
                   "org.freedesktop.policykit.exec.argv1": a.get("id").split(".")[-1]}, ann
d = [a for a in t.getroot().iter("action") if a.get("id").endswith("delete")][0]
assert d.find("defaults/allow_active").text == "auth_admin_keep"' "$SNAPSRC/root/org.lares.snapshot.policy"
check hook.files.shape python3 -B -c '
import sys, configparser
def load(p):
    c = configparser.ConfigParser(allow_no_value=True, strict=False); c.optionxform = str; c.read_string(open(p).read()); return c
pre = load(sys.argv[1] + "/00-lares-snapshot.hook"); done = load(sys.argv[1] + "/zz-lares-snapshot-done.hook")
assert pre["Action"]["When"] == "PreTransaction" and "AbortOnFail" in pre["Action"] and "NeedsTargets" in pre["Action"]
assert pre["Action"]["Exec"] == "/usr/local/lib/lares/snapshot/hook pre"
assert done["Action"]["When"] == "PostTransaction" and "AbortOnFail" not in done["Action"] and "NeedsTargets" in done["Action"]
assert done["Action"]["Exec"] == "/usr/local/lib/lares/snapshot/hook done"
t = open(sys.argv[1] + "/00-lares-snapshot.hook").read()
assert "Operation = Remove" not in t and "Operation = Install" in t and "Operation = Upgrade" in t     # a removal alone never asks
assert "Operation = Remove" in open(sys.argv[1] + "/zz-lares-snapshot-done.hook").read()' "$SNAPSRC/root"

# ==================================================== the polkit rule, evaluated by node ==========================================
sed 's/@USER@/tester/g' "$SRC/50-lares-snapshot.rules.in" > "$W/rule.js"
cat > "$W/rule_test.js" <<'EOF'
const fs = require("fs");
let rule = null;
const polkit = { addRule: (f) => { rule = f; }, Result: { YES: "yes" } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const T = "/usr/local/lib/lares/snapshot/lares-snapshot-root";
const ok = { user: "tester", local: true, active: true };
const act = (id, kv) => ({ id, lookup: (k) => (kv || {})[k] });
const exec = (cl) => act("org.freedesktop.policykit.exec", { program: T, command_line: cl });
const cases = [
    ["create action", ok, act("org.lares.snapshot.create"), "yes"],
    ["keep action", ok, act("org.lares.snapshot.keep"), "yes"],
    ["delete action asks", ok, act("org.lares.snapshot.delete"), undefined],
    ["pkexec's own action asks (no rule for a verb by its command line)", ok, exec(T + " create"), undefined],
    ["pkexec's own action asks for tidy", ok, exec(T + " tidy"), undefined],
    ["another user asks", { user: "other", local: true, active: true }, act("org.lares.snapshot.create"), undefined],
    ["a remote session asks", { user: "tester", local: false, active: true }, act("org.lares.snapshot.create"), undefined],
    ["an inactive session asks", { user: "tester", local: true, active: false }, act("org.lares.snapshot.keep"), undefined],
];
let bad = 0;
for (const [name, subject, action, want] of cases) {
    const got = rule(action, subject);
    if (got !== want) { console.log("rule case failed: " + name + " gave " + got); bad++; }
}
process.exit(bad ? 1 : 0);
EOF
check polkit.rule node "$W/rule_test.js" "$W/rule.js"

# ==================================================== the fake root ===================================================================
FR=$W/root
CALLS=$W/calls.log
mkdir -p "$FR/etc/pacman.d" "$FR/etc/polkit-1/rules.d" "$FR/usr/share/polkit-1/actions" "$FR/usr/local/lib" "$FR/usr/bin"
mkdir -p "$W/bin"
cat > "$W/bin/id" <<EOF
#!/bin/sh
[ "\$1" = -u ] && [ \$# = 1 ] && { echo 0; exit 0; }
exec /usr/bin/id "\$@"
EOF
cat > "$W/bin/pacman" <<EOF
#!/bin/sh
echo "pacman \$* lib=\$([ -e "$FR/usr/local/lib/lares/snapshot" ] && echo yes || echo no) hooks=\$(ls "$FR/etc/pacman.d/hooks" 2>/dev/null | tr '\n' ' ')" >> "$CALLS"
EOF
# install / rm log what they are asked to do, then do it (the order of the hooks and of the removals is what is proven)
for t in install rm; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexec /usr/bin/%s "$@"\n' "$t" "$CALLS" "$t" > "$W/bin/$t"
done
# the tool's `init`: makes the key and the repository folder the way the real one does, and says what stood there at that moment
cat > "$FR/usr/bin/python3" <<EOF
#!/bin/sh
echo "init \$* lib=\$([ -x "$FR/usr/local/lib/lares/snapshot/lares-snapshot-root" ] && echo tool || echo none) hooks=\$(ls "$FR/etc/pacman.d/hooks" 2>/dev/null | tr '\n' ' ')" >> "$CALLS"
mkdir -p "$FR/.lares-snapshots/repo" && printf 'TESTPASSWORD-9f3a\n' > "$FR/.lares-snapshots/key"
EOF
chmod +x "$W"/bin/* "$FR/usr/bin/python3"

to_fake_root() {   # to_fake_root <script>: its path variables and every /etc /usr /run /var path after a space, = or " moved into the fake root
    sed -E -e "s#^(LIB|ETCLARES|PYTHON|HOOKDIR|POLICY|RULE|STATE)=/#\\1=$FR/#" -e "s#([ =\"])/(etc|usr|run|var)/#\\1$FR/\\2/#g" -e 's/ -o root -g root//' "$1"
}
paths_all_moved() {   # no line of the moved script (comments and printed text aside) still names a real path
    sed -e "s#$FR/#@FR@/#g" "$1" | grep -vE '^[[:space:]]*(#|echo|printf)' | grep -nE '(^|[^[:alnum:]_.$}/@-])/(etc|usr|run|var|opt|home|boot)/' > "$W/refused.txt" && { cat "$W/refused.txt"; return 1; }
    return 0
}
real_before() { ls -la --time-style=+%s /etc/pacman.d/hooks /usr/local/lib/lares /etc/polkit-1/rules.d /usr/share/polkit-1/actions/org.lares.snapshot.policy /.lares-snapshots 2> /dev/null | sha256sum; }
REAL0=$(real_before)

to_fake_root "$SRC/install.sh" > "$SRC/.install.moved"; to_fake_root "$SRC/uninstall.sh" > "$SRC/.uninstall.moved"
paths_ok=1
check install.sh.paths.all.in.the.fake.root paths_all_moved "$SRC/.install.moved" || paths_ok=0
check uninstall.sh.paths.all.in.the.fake.root paths_all_moved "$SRC/.uninstall.moved" || paths_ok=0
if [ "$paths_ok" = 0 ]; then
    echo "(a line names a real path: nothing was run)"
else
    run() { # run <script> <stdin> [env...]
        local s=$1 in=$2; shift 2
        printf '%s\n' "$in" | env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" FR="$FR" CALLS="$CALLS" "$@" bash "$s" > "$W/run.out" 2> "$W/run.err"
    }
    tree() { (cd "$FR" && find . -type f -o -type l | sort | xargs -r sha256sum); }
    tree > "$W/tree.pristine"

    # ---- refusals change nothing ----
    : > "$CALLS"
    run "$SRC/.install.moved" yes SUDO_USER=; rc=$?
    check install.refuses.without.sudo.user bash -c '[ "$1" != 0 ] && [ ! -s "$2" ] && diff -q "$3" <(cd "$4" && find . -type f -o -type l | sort | xargs -r sha256sum) > /dev/null' _ "$rc" "$CALLS" "$W/tree.pristine" "$FR"
    run "$SRC/.install.moved" yes 'SUDO_USER=bad;name'; rc=$?
    check install.refuses.a.bad.user.name bash -c '[ "$1" != 0 ] && [ ! -s "$2" ]' _ "$rc" "$CALLS"
    run "$SRC/.install.moved" no SUDO_USER=tester; rc=$?
    check install.no.changes.nothing bash -c '[ "$1" != 0 ] && [ ! -s "$2" ] && grep -q "nothing changed" "$3"' _ "$rc" "$CALLS" "$W/run.out"

    # ---- the install ----
    : > "$CALLS"
    run "$SRC/.install.moved" yes SUDO_USER=tester; rc=$?
    check install.runs bash -c '[ "$1" = 0 ]' _ "$rc"
    LIBD=$FR/usr/local/lib/lares/snapshot
    modes() { stat -c '%a %U' "$@"; }
    check install.files bash -c '
        L=$1; R=$2
        [ -x "$L/lares-snapshot-root" ] && [ -x "$L/hook" ] && [ -f "$L/snaprules.py" ] && [ -f "$L/jsonc.py" ] && [ -f "$L/defaults.json" ] \
          && [ "$(cat "$L/user")" = tester ] && cmp -s "$R/tools/lib/jsonc.py" "$L/jsonc.py" && cmp -s "$R/tools/snapshot/root/snaprules.py" "$L/snaprules.py" \
          && [ "$(stat -c %a "$L/lares-snapshot-root")" = 755 ] && [ "$(stat -c %a "$L/snaprules.py")" = 644 ]' _ "$LIBD" "$W"
    check install.hooks.in.place bash -c '
        H=$1/etc/pacman.d/hooks; cmp -s "$H/00-lares-snapshot.hook" "$2/00-lares-snapshot.hook" && cmp -s "$H/zz-lares-snapshot-done.hook" "$2/zz-lares-snapshot-done.hook"' _ "$FR" "$SRC"
    check install.etc.lares bash -c '[ -d "$1/etc/lares" ] && [ "$(stat -c %a "$1/etc/lares")" = 755 ]' _ "$FR"
    check install.polkit.in.place bash -c '
        cmp -s "$1/usr/share/polkit-1/actions/org.lares.snapshot.policy" "$2/org.lares.snapshot.policy" && grep -q "subject.user != \"tester\"" "$1/etc/polkit-1/rules.d/50-lares-snapshot.rules" && ! grep -q "@USER@" "$1/etc/polkit-1/rules.d/50-lares-snapshot.rules"' _ "$FR" "$SRC"
    # the ORDER is the safety: pacman first (the lib is not there yet), the tool, then init (tool there, no hook), then the rescue (no hook), the hooks last
    check order.pacman.first bash -c 'head -1 "$1" | grep -q "^pacman -S --needed restic lib=no hooks= *$"' _ "$CALLS"
    check order.init.after.tool.before.hooks bash -c 'grep -q "^init -I .*lares-snapshot-root init lib=tool hooks= *$" "$1"' _ "$CALLS"
    check order.rescue.before.hooks bash -c 'grep -q "^rescue-install hooks= *$" "$1"' _ "$CALLS"
    check order.hooks.last bash -c '
        # the last two installs of the run are the done hook, then the pre hook; nothing is installed after them; init and the rescue came before
        mapfile -t i < <(grep -n "^install " "$1" | cut -d: -f1); n=${#i[@]}
        z=$(grep -n "^install .*zz-lares-snapshot-done.hook" "$1" | tail -1 | cut -d: -f1); p=$(grep -n "^install .*00-lares-snapshot.hook" "$1" | tail -1 | cut -d: -f1)
        t=$(grep -n "^init " "$1" | cut -d: -f1); r=$(grep -n "^rescue-install" "$1" | cut -d: -f1)
        [ -n "$z" ] && [ -n "$p" ] && [ "$z" -lt "$p" ] && [ "$p" -eq "${i[$((n-1))]}" ] && [ "$z" -gt "$t" ] && [ "$z" -gt "$r" ] && [ "$p" -gt "$r" ]' _ "$CALLS"
    check install.password.once.at.the.end bash -c '
        [ "$(grep -c TESTPASSWORD-9f3a "$1")" = 1 ] && grep -q "password manager" "$1" && [ "$(grep -n TESTPASSWORD "$1" | cut -d: -f1)" -gt "$(grep -n "^Installed" "$1" | cut -d: -f1)" ]' _ "$W/run.out"
    check install.touched.nothing.real bash -c '[ "$1" = "$2" ]' _ "$REAL0" "$(real_before)"

    # ---- a second run changes no file ----
    tree > "$W/tree.first"; : > "$CALLS"
    run "$SRC/.install.moved" yes SUDO_USER=tester
    check install.twice.same.files bash -c 'diff <(sed "/\\.lares-snapshots/d" "$1") <(cd "$2" && find . -type f -o -type l | sort | xargs -r sha256sum | sed "/\\.lares-snapshots/d") > /dev/null' _ "$W/tree.first" "$FR"

    # ---- the uninstall ----
    : > "$CALLS"
    printf 'x' > "$FR/.lares-snapshots/repo/config"
    run "$SRC/.uninstall.moved" "" ; rc=$?
    check uninstall.runs bash -c '[ "$1" = 0 ]' _ "$rc"
    check uninstall.hooks.first bash -c '
        # the first rm of the run names both hooks; the rescue uninstall sees no hook; the tool goes after
        first=$(grep -n "^rm " "$1" | head -1); echo "$first" | grep -q "00-lares-snapshot.hook" && echo "$first" | grep -q "zz-lares-snapshot-done.hook" \
          && grep -q "^rescue-uninstall hooks= *$" "$1" && [ "$(grep -n "^rm " "$1" | head -1 | cut -d: -f1)" -lt "$(grep -n "rm -rf .*lares/snapshot" "$1" | head -1 | cut -d: -f1)" ]' _ "$CALLS"
    check uninstall.removes.everything bash -c '
        [ ! -e "$1/usr/local/lib/lares/snapshot" ] && [ ! -e "$1/etc/pacman.d/hooks/00-lares-snapshot.hook" ] && [ ! -e "$1/etc/pacman.d/hooks/zz-lares-snapshot-done.hook" ] \
          && [ ! -e "$1/etc/lares" ] && [ ! -e "$1/etc/polkit-1/rules.d/50-lares-snapshot.rules" ] && [ ! -e "$1/usr/share/polkit-1/actions/org.lares.snapshot.policy" ]' _ "$FR"
    check uninstall.keeps.snapshots bash -c '[ -f "$1/.lares-snapshots/repo/config" ] && [ -f "$1/.lares-snapshots/key" ] && grep -q "sudo rm -rf $1/.lares-snapshots" "$2"' _ "$FR" "$W/run.out"
    # a break-glass file in /etc/lares is never removed with it
    run "$SRC/.install.moved" yes SUDO_USER=tester; touch "$FR/etc/lares/snapshot.off"; run "$SRC/.uninstall.moved" ""
    check uninstall.keeps.the.off.file bash -c '[ -f "$1/etc/lares/snapshot.off" ]' _ "$FR"
    rm -rf "$FR/etc/lares" "$FR/.lares-snapshots"
    check uninstall.touched.nothing.real bash -c '[ "$1" = "$2" ]' _ "$REAL0" "$(real_before)"
fi

# ==================================================== the wrapper ===================================================================
# the wrapper's own path lines moved into a world of stubs; every case is one world
WR=$W/wrap
mkdir -p "$WR"
mkworld() {   # mkworld <name> [flags]: tool, python, restic, repo present; flags remove or break one thing
    local w=$WR/$1; shift
    rm -rf "$w"; mkdir -p "$w/lib" "$w/state/repo" "$w/etc" "$w/bin"
    printf '#!/bin/sh\ncat > "%s/stdin.txt"\necho "lares-snapshot: start fake"\nexit ${TOOL_RC:-0}\n' "$w" > "$w/lib/lares-snapshot-root"
    printf '#!/bin/sh\nshift; exec "$@"\n' > "$w/py"
    printf '#!/bin/sh\n[ "$1" = version ] && exit ${RESTIC_RC:-0}\nexit 0\n' > "$w/restic"
    printf '#!/bin/sh\nexit ${CHROOT_RC:-1}\n' > "$w/detect"
    chmod +x "$w/lib/lares-snapshot-root" "$w/py" "$w/restic" "$w/detect"
    : > "$w/state/repo/config"; : > "$w/state/key"
    for flag in "$@"; do
        case $flag in
            notool) rm "$w/lib/lares-snapshot-root" ;;
            nopython) rm "$w/py" ;;
            norepo) rm "$w/state/repo/config" ;;
            nokey) rm "$w/state/key" ;;
            off) : > "$w/etc/off" ;;
        esac
    done
    sed -E -e "s#^LIB=.*#LIB=$w/lib#" -e "s#^STATE=.*#STATE=$w/state#" -e "s#^OFF=.*#OFF=$w/etc/off#" -e "s#^PY=.*#PY=$w/py#" \
        -e "s#^RESTIC=.*#RESTIC=$w/restic#" -e "s#^DETECT=.*#DETECT=$w/detect#" "$SRC/hook" > "$w/hook"
    chmod +x "$w/hook"
}
runhook() {   # runhook <world> <mode> [env...]  -> $W/h.out, status in $hrc; the python stub eats the `-I`
    local w=$WR/$1 m=$2; shift 2
    printf 'linux\nmesa\n' | env -i PATH=/usr/bin:/bin "$@" sh "$w/hook" "$m" > "$W/h.out" 2> "$W/h.err"; hrc=$?
}
expect_skip() {   # expect_skip <world> <code> <mode> [env...]
    local w=$1 code=$2 m=${3:-pre}; shift 3
    runhook "$w" "$m" "$@"
    [ "$hrc" = 0 ] || { echo "status $hrc"; return 1; }
    if [ "$m" = done ]; then [ ! -s "$W/h.out" ] || { echo "done spoke: $(cat "$W/h.out")"; return 1; }; return 0; fi
    [ "$(cat "$W/h.out")" != "" ] && [ "$(wc -l < "$W/h.out")" = 1 ] && grep -q "^lares-snapshot: skip $code " "$W/h.out" || { cat "$W/h.out"; return 1; }
}
mkworld ok;       check wrapper.runs.the.tool bash -c "$(declare -f runhook); WR=$WR W=$W SRC=$SRC; runhook ok pre; [ \$hrc = 0 ] && grep -q 'start fake' \$W/h.out && [ \"\$(cat \$WR/ok/stdin.txt)\" = \"\$(printf 'linux\nmesa')\" ]"
mkworld notool notool;     check wrapper.skip.no.tool bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip notool tool pre"
mkworld nopy nopython;     check wrapper.skip.no.python bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip nopy tool pre"
mkworld norepo norepo;     check wrapper.skip.no.repo bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip norepo repo pre"
mkworld nokey nokey;       check wrapper.skip.no.key bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip nokey repo pre"
mkworld off off;           check wrapper.skip.off bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip off off pre"
mkworld rbad;              check wrapper.skip.restic.broken bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip rbad tool pre RESTIC_RC=127"
mkworld chroot;            check wrapper.skip.chroot bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip chroot chroot pre CHROOT_RC=0"
mkworld notool2 notool;    check wrapper.done.is.silent bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip notool2 tool done; expect_skip notool2 tool done"
mkworld off2 off;          check wrapper.done.off.is.silent bash -c "$(declare -f runhook expect_skip); WR=$WR W=$W; expect_skip off2 off done"
mkworld crash
# 20000 names are 180 KB, more than a pipe holds: a skip that leaves them unread ends the writer with SIGPIPE (pacman writes the targets)
mkworld drain off
check wrapper.reads.every.target bash -c "set -o pipefail; for m in pre done; do seq -f 'package%05g' 20000 | sh $WR/drain/hook \$m > /dev/null || { echo \"\$m: a writer was cut\"; exit 1; }; done"
check wrapper.crash.lets.pacman.go bash -c "$(declare -f runhook); WR=$WR W=$W; for rc in 2 70 127 139; do runhook crash pre TOOL_RC=\$rc; [ \$hrc = 0 ] && grep -q '^lares-snapshot: skip tool ' \$W/h.out || { echo \"rc \$rc -> \$hrc: \$(cat \$W/h.out)\"; exit 1; }; done"
check wrapper.failure.stops.pacman bash -c "$(declare -f runhook); WR=$WR W=$W; runhook crash pre TOOL_RC=1; [ \$hrc = 1 ] && ! grep -q skip \$W/h.out"
check wrapper.bad.argument bash -c "$(declare -f runhook); WR=$WR W=$W; runhook ok tidy; [ \$hrc = 0 ] && grep -q 'skip tool' \$W/h.out"

# ====================================================================================================================================
if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS"; exit 0; fi
echo "$NAME RESULT FAIL"; exit 1
