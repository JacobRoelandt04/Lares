#!/usr/bin/env bash
# snapshot_setup_probe.sh -- `lares setup`'s rows for the system snapshots (R5) and for SSD TRIM, on a FAKE ROOT, and the printed R5 step run
# AS PRINTED with stubs for sudo, lares and proton-drive that only write down what they were asked (nothing is installed, no sudo is run,
# the real installer is never started: tools/dev/snapshot_install_probe.sh proves that one on its own fake root).
#
#   tools/dev/snapshot_setup_probe.sh             SNAPSHOT_SETUP RESULT PASS | FAIL
#   ARM=todoalways    an optional row that nobody asked for counts as a TO DO     -> "not installed, no config: not a TO DO"
#   ARM=trimhdd       the TRIM row also shows for a spinning disk                 -> "a spinning disk: no TRIM row"
#   ARM=timeshiftalways  the Timeshift removal is printed with no Timeshift      -> "no Timeshift: nothing printed about it"
#   ARM=halfokay      a tool with no hooks reads as installed                     -> "hooks missing is half installed: TO DO"
#
# A copy of tools/shell is the code under test (an arm patches that copy only). `lares setup` reads the machine as it is (read only); HOME,
# the runtime dir, the root prefix, /sys/block and systemctl are the probe's own.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ "${ARM:-}" = all ]; then   # every arm in turn, each its own run
    bad=0
    for a in todoalways trimhdd timeshiftalways halfokay; do
        out=$(ARM=$a "$0" 2>&1 | tail -1); echo "  $out"
        case $out in *"failed as it must"*) ;; *) bad=1 ;; esac
    done
    [ "$bad" = 0 ] && { echo "SNAPSHOT_SETUP ARMS PASS"; exit 0; }
    echo "SNAPSHOT_SETUP ARMS FAIL"; exit 1
fi
W="$(mktemp -d "${SCRATCH:-/tmp}/sns.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/rt" "$W/stubs" "$W/repo/tools/shell" "$W/repo/tools/snapshot/root"
chmod 700 "$W/rt"
cp -p tools/shell/lares "$W/repo/tools/shell/lares"
for f in tools/shell/*; do [ -f "$f" ] && [ ! -e "$W/repo/$f" ] && cp -p "$f" "$W/repo/$f"; done
patch() {   # patch <old> <new>: one exact anchor in the copy, or the arm is gone
    python3 - "$W/repo/tools/shell/lares" "$1" "$2" << 'PY' || { echo "ARM anchor gone"; exit 3; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
sys.exit(1) if s.count(a) != 1 else open(p, "w").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
    "") ;;
    todoalways) patch '    snap_config_in && todo=1' '    todo=1' ;;
    trimhdd) patch '[ "$(cat "$d/queue/rotational" 2> /dev/null)" = 0 ] && ' '' ;;
    timeshiftalways) patch 'snap_timeshift_in() { [ -e' 'snap_timeshift_in() { return 0; [ -e' ;;
    halfokay) patch '    snap_hooks_in || { echo halfhooks; return; }
' '' ;;
    *) echo "unknown ARM=${ARM:-}"; exit 2 ;;
esac
# stubs: they write down their argv and do nothing else
for c in sudo lares proton-drive; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$STUBLOG"\n' "$c" > "$W/stubs/$c"
done
cat > "$W/stubs/systemctl" << 'STUB'
#!/bin/sh
[ "$1" = is-enabled ] && [ "$2" = fstrim.timer ] && { cat "$TRIMSTATE" 2> /dev/null || echo disabled; [ "$(cat "$TRIMSTATE" 2> /dev/null)" = enabled ]; exit; }
exit 1
STUB
chmod +x "$W/stubs/"*
SNAPREL=tools/snapshot/root
run_setup() {   # run_setup <name>: lares setup against the world $W/w-<name> (root prefix, home, /sys/block)
    local w="$W/w-$1"
    mkdir -p "$w/home" "$w/root" "$w/sys"
    env -i PATH="$W/stubs:/usr/bin:/bin" HOME="$w/home" XDG_RUNTIME_DIR="$W/rt" LARES_ROOT_PREFIX="$w/root" LARES_REPO="$W/repo" \
        LARES_SYS_BLOCK="$w/sys" LARES_SYSTEMCTL="$W/stubs/systemctl" TRIMSTATE="$w/trim" \
        timeout 90 "$W/repo/tools/shell/lares" setup > "$W/$1.out" 2>&1
}
world() {   # world <name> <what...>: tool hooks repo index rescue timeshift config deployed hdd ssd trimon
    local n=$1 w="$W/w-$1" x; shift
    mkdir -p "$w/home" "$w/root" "$w/sys"
    for x in "$@"; do
        case $x in
            tool) mkdir -p "$w/root/usr/local/lib/lares/snapshot"; : > "$w/root/usr/local/lib/lares/snapshot/lares-snapshot-root" ;;
            hooks) mkdir -p "$w/root/etc/pacman.d/hooks"; : > "$w/root/etc/pacman.d/hooks/00-lares-snapshot.hook"; : > "$w/root/etc/pacman.d/hooks/zz-lares-snapshot-done.hook" ;;
            repo) mkdir -p "$w/root/.lares-snapshots/repo" ;;
            index) mkdir -p "$w/root/.lares-snapshots"; printf '%s\t1800000000\tupdate\tBefore 50 packages\n%s\t1799000000\tmanual\tManual\n' "a$(printf 'b%.0s' 1 2 3 4 5 6 7)" "c$(printf 'd%.0s' 1 2 3 4 5 6 7)" > "$w/root/.lares-snapshots/index.tsv" ;;
            rescue) mkdir -p "$w/root/boot/lares" "$w/root/etc/grub.d"; : > "$w/root/boot/lares/rescue.img"; : > "$w/root/etc/grub.d/45_lares_rescue" ;;
            timeshift) mkdir -p "$w/root/usr/bin" "$w/root/timeshift"; : > "$w/root/usr/bin/timeshift" ;;
            config) mkdir -p "$w/home/.config/quickshell/config"; echo '{}' > "$w/home/.config/quickshell/config/snapshots.jsonc" ;;
            deployed) mkdir -p "$w/home/.local/state/lares/shell/current/$SNAPREL"
                for f in install.sh uninstall.sh; do printf '#!/bin/sh\n' > "$w/home/.local/state/lares/shell/current/$SNAPREL/$f"; chmod +x "$w/home/.local/state/lares/shell/current/$SNAPREL/$f"; done ;;
            hdd) mkdir -p "$w/sys/sda/queue"; echo 1 > "$w/sys/sda/queue/rotational"; echo 4096 > "$w/sys/sda/queue/discard_max_bytes" ;;
            ssd) mkdir -p "$w/sys/nvme0n1/queue"; echo 0 > "$w/sys/nvme0n1/queue/rotational"; echo 2199023255040 > "$w/sys/nvme0n1/queue/discard_max_bytes" ;;
            trimon) echo enabled > "$w/trim" ;;
        esac
    done
}
BAD=0
check() { local what=$1; shift; if "$@" > /dev/null 2>&1; then echo "SNS ok   $what"; else echo "SNS FAIL $what" | tee -a "$W/fails"; BAD=$((BAD + 1)); fi; }
row() { grep -aE "^  (ok|TO DO|-) +$2 " "$1"; }
world none hdd
world nodeploy_cfg config hdd
world deployed deployed hdd
world halfhooks tool config hdd; rm -rf "$W/w-halfhooks/home/.config"; world halfhooks tool hdd
world halftool hooks hdd
world nosnap tool hooks repo hdd
world norescue tool hooks repo index hdd
world fine tool hooks repo index rescue hdd
world fineshift tool hooks repo index rescue timeshift hdd
world shift deployed timeshift hdd
world ssdoff ssd
world ssdon ssd trimon
for n in none nodeploy_cfg deployed halfhooks halftool nosnap norescue fine fineshift shift ssdoff ssdon; do run_setup "$n"; done
todos() { grep -acE '^  TO DO ' "$1"; }
check "nothing installed, no config: a dash row, not a TO DO, and the R5 step is printed" bash -c '
    grep -aqE "^  - +R5 system snapshots +not installed \(optional" "$1" && grep -aq "^R5  SYSTEM SNAPSHOTS" "$1" && ! grep -aqE "^  TO DO +R5" "$1"' _ "$W/none.out"
check "with config/snapshots.jsonc the same state is a TO DO (one more than without)" bash -c '
    grep -aqE "^  TO DO +R5 system snapshots +not installed" "$1" && [ "$(grep -acE "^  TO DO " "$1")" -eq "$(( $(grep -acE "^  TO DO " "$2") + 1 ))" ]' _ "$W/nodeploy_cfg.out" "$W/none.out"
check "no deployed snapshot: the installer line says to deploy first, and prints no path" bash -c 'grep -aq "(after .lares deploy.: the installer comes from" "$1" && ! grep -aqE "^      sudo .*install.sh" "$1"' _ "$W/none.out"
check "a deployed snapshot: the installer and the uninstaller are the snapshot copy (not the repo)" bash -c '
    d="$2/home/.local/state/lares/shell/current/tools/snapshot/root"
    grep -aqx "      sudo $d/install.sh" "$1" && grep -aqx "      sudo $d/uninstall.sh" "$1"' _ "$W/deployed.out" "$W/w-deployed"
check "the tool without its hooks is half installed: TO DO, names the hooks" bash -c 'grep -aE "^  TO DO +R5" "$1" | grep -aq "pacman hooks are missing"' _ "$W/halfhooks.out"
check "hooks without the tool is half installed: TO DO" bash -c 'grep -aE "^  TO DO +R5" "$1" | grep -aq "hooks are in /etc/pacman.d/hooks but the tool is not"' _ "$W/halftool.out"
check "installed with no snapshot yet: a dash row naming lares snapshot create, no TO DO" bash -c 'grep -aE "^  - +R5" "$1" | grep -aq "no snapshot yet: lares snapshot create"' _ "$W/nosnap.out"
check "installed, snapshots, no rescue: a dash row with the count and the newest date" bash -c 'grep -aE "^  - +R5" "$1" | grep -aq "2 snapshot(s), the newest 2027-.*rescue image or its GRUB entry is missing"' _ "$W/norescue.out"
check "fine: an ok row with the count and the newest, no R5 step, nothing about Timeshift" bash -c '
    grep -aE "^  ok +R5" "$1" | grep -aq "2 snapshot(s), the newest .*the rescue is built" && ! grep -aq "^R5  " "$1" && ! grep -aqi timeshift "$1"' _ "$W/fine.out"
check "fine with Timeshift installed: only the Timeshift removal is printed, marked irreversible, three commands in order" bash -c '
    grep -aq "^    Timeshift, LAST" "$1" && grep -aq "IRREVERSIBLE" "$1" && ! grep -aq "^R5  SYSTEM" "$1" &&
    [ "$(grep -aE "^      sudo (timeshift --delete-all|rm -rf /timeshift|pacman -Rns timeshift)$" "$1" | tr "\n" "|")" = "      sudo timeshift --delete-all|      sudo rm -rf /timeshift|      sudo pacman -Rns timeshift|" ]' _ "$W/fineshift.out"
check "no Timeshift on the machine: nothing about it is printed" bash -c '! grep -aqi "timeshift" "$1"' _ "$W/none.out"
check "an SSD that takes discards with fstrim.timer off: an informational TRIM row with the command and the honest cause" bash -c '
    grep -aE "^  - +SSD TRIM" "$1" | grep -aq "sudo systemctl enable --now fstrim.timer" && grep -aE "^  - +SSD TRIM" "$1" | grep -aq "before its first TRIM" && ! grep -aE "^  TO DO +SSD" "$1"' _ "$W/ssdoff.out"
check "with fstrim.timer enabled the TRIM row is ok" bash -c 'grep -aqE "^  ok +SSD TRIM +fstrim.timer is enabled" "$1"' _ "$W/ssdon.out"
check "a spinning disk: no TRIM row" bash -c '! grep -aq "SSD TRIM" "$1"' _ "$W/none.out"
# the printed R5 step, as printed: every command line goes to a stub that writes it down
export STUBLOG="$W/stub.log"; : > "$STUBLOG"
awk '/^R5  /{on=1} on' "$W/shift.out" | grep -aE '^      (sudo |lares |proton-drive )' | sed 's/^ *//' > "$W/cmds.sh"
( cd "$W" && PATH="$W/stubs:/usr/bin:/bin" bash "$W/cmds.sh" > /dev/null 2>&1 )
EXPECT="sudo $W/w-shift/home/.local/state/lares/shell/current/tools/snapshot/root/install.sh
lares snapshot create
lares snapshot rescue status
proton-drive auth login
lares snapshot offsite try
sudo timeshift --delete-all
sudo rm -rf /timeshift
sudo pacman -Rns timeshift
sudo $W/w-shift/home/.local/state/lares/shell/current/tools/snapshot/root/uninstall.sh"
check "the printed R5 commands run as printed, in this order: installer, create, rescue status, Proton login, offsite try, Timeshift's three, uninstaller" test "$(cat "$STUBLOG")" = "$EXPECT"
check "the installer the step names exists in the deployed copy and is executable" bash -c 'f=$(sed -n "1p" "$1" | sed "s/^sudo //"); [ -x "$f" ]' _ "$W/cmds.sh"
# (the packages' rows ask fc-list, and fontconfig keeps its own cache in a home that has none)
check "the setup run wrote nothing into the home or the fake root" bash -c '[ -z "$(find "$1/home" "$1/root" -newer "$2" -type f ! -path "$1/home/.cache/fontconfig/*" 2> /dev/null)" ]' _ "$W/w-none" "$W/rt"
if [ -n "${ARM:-}" ]; then
    case "$ARM" in todoalways) needle="not a TO DO" ;; trimhdd) needle="a spinning disk" ;; timeshiftalways) needle="no Timeshift on the machine" ;; halfokay) needle="without its hooks" ;; esac
    if grep -aq "^SNS FAIL .*$needle" "$W/fails" 2> /dev/null; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
if [ "$BAD" -eq 0 ]; then echo "SNAPSHOT_SETUP RESULT PASS"; exit 0; fi
KEEP=1; echo "SNAPSHOT_SETUP RESULT FAIL ($BAD red: $W)"; exit 1
