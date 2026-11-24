#!/usr/bin/env bash
# The aerial test bed's INSTALL, proven without root (tools/aerial/rig/, docs/.../aerial_progress/R.md): what the user's one command
# would write, where, byte for byte -- install.sh and uninstall.sh run AS THEY ARE on a FAKE ROOT (a temp dir standing in for /, every
# path rewritten into it, `id` saying root, pacman / systemctl / nmcli stubs that log), plus every static check the rig's files can
# take today: the shell syntax, dnsmasq --test, the private bus config parsed by a real dbus-daemon, the rig's NetworkManager config
# parsed by the real NetworkManager (--print-config, as you), the unit through systemd-analyze verify, the hostapd keys against the
# upstream reference list (hostapd is not installed), the polkit rule evaluated with node, the placeholders, the namespace order.
#
#   tools/dev/aerial_rig_install_probe.sh                 last line: AERIAL_RIG_INSTALL RESULT PASS|FAIL (exit status follows)
#   ARM=<name> tools/dev/aerial_rig_install_probe.sh      a fault in a COPY of the rig's files; the run must end FAIL on the arm's own check
#   ARM=all tools/dev/aerial_rig_install_probe.sh         every ARM; AERIAL_RIG_INSTALL ARMS PASS when each failed as it must
#
#     realpath   an install line that names a real /etc path (written with a tab, which the move to the fake root does not touch)
#                                                          -> `install.sh.paths.all.in.the.fake.root` FAILS
#     nouser     the polkit rule without the user's name   -> `polkit.rule.names.the.user` FAILS
#
# It never runs anything as root, never touches /etc, /usr/local or the real NetworkManager, and starts no quickshell.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_RIG_INSTALL
RIGSRC=$PWD/tools/aerial/rig

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in realpath nouser; do
        case $a in realpath) needle="AIR install.sh.paths.all.in.the.fake.root FAIL" ;; nouser) needle="AIR polkit.rule.names.the.user FAIL" ;; esac
        res=$(ARM=$a bash "$0" 2>&1)
        if printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -qF "$needle"; then echo "  ARM $a: failed, but not on its own check ($needle)"; bad=1
        else echo "  ARM $a: failed as it must ($needle)"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
ARM=${ARM:-}

SB=${SANDBOX:-/tmp/lares-sbx-aerial-r}
mkdir -p "$SB" || exit 1
W=$(mktemp -d "$SB/air.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
fail=0
check() {   # check <name> <command...>
    local n=$1; shift
    if "$@" > "$W/last.out" 2>&1; then echo "AIR $n PASS"; return 0; fi
    echo "AIR $n FAIL  $(head -c 300 "$W/last.out" | tr '\n' ' ')"; fail=1; return 1
}

# ---- a COPY of the rig's files (the arms patch the copy, never the tree) --------------------------------------------------------------
SRC=$W/src; cp -a "$RIGSRC" "$SRC"
case $ARM in
    '') ;;
    nouser) python3 - "$SRC/install.sh" <<'PY' || { echo "ARM nouser: anchor missing"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p = sys.argv[1]; s = open(p).read(); a = 'subject.user == "$USER_NAME"'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, 'subject.user == ""'))
PY
    ;;
    realpath) python3 - "$SRC/install.sh" <<'PY' || { echo "ARM realpath: anchor missing"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p = sys.argv[1]; s = open(p).read(); a = '\nsystemctl daemon-reload\n'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, '\ntouch\t/etc/lares-aerial-rig-arm\n' + a[1:]))
PY
    ;;
    *) echo "unknown ARM $ARM"; exit 2 ;;
esac

# ==================================================== static: the files parse ======================================================
check syntax.bash bash -c 'for f in rig install.sh uninstall.sh; do bash -n "$1/$f" || exit 1; done' _ "$RIGSRC"
check syntax.portal python3 -m py_compile "$RIGSRC/portal.py"
check dnsmasq.test dnsmasq --test --conf-file="$RIGSRC/conf/dnsmasq.conf"

# the private bus: a real dbus-daemon reads bus.conf and prints its address (the socket moved into the world)
sed "s|/run/lares-rig/bus|$W/bus|" "$RIGSRC/conf/bus.conf" > "$W/bus.conf"
dbus-daemon --nofork --config-file="$W/bus.conf" --print-address > "$W/bus.out" 2> "$W/bus.err" &
bpid=$!
for _ in $(seq 30); do [ -S "$W/bus" ] && break; sleep 0.1; done
check bus.conf.parses bash -c '[ -S "$1/bus" ] && grep -q "^unix:path=$1/bus" "$1/bus.out" && [ ! -s "$1/bus.err" ]' _ "$W"
kill "$bpid" 2> /dev/null; wait "$bpid" 2> /dev/null

# the rig's NetworkManager config, as the real NetworkManager reads it (it prints and exits; no root, no bus)
mkdir -p "$W/nmc" "$W/nms" "$W/run/keyfiles"
sed -e "s/@CLIENT@/wlan2/" -e "s|@RUN@|$W/run|" "$RIGSRC/conf/nm.conf" > "$W/nm.conf"
NetworkManager --print-config --config="$W/nm.conf" --config-dir="$W/nmc" --system-config-dir="$W/nms" --intern-config="$W/intern.conf" > "$W/nm.print" 2> "$W/nm.perr"
nmv() { sed -n "/^\[$1\]/,/^\[/p" "$W/nm.print" | grep -x "$2"; }
check nm.dns.none nmv main 'dns=none'
check nm.rc-manager.unmanaged nmv main 'rc-manager=unmanaged'
check nm.polkit.off nmv main 'auth-polkit=false'
check nm.keyfile.in.the.run.dir nmv keyfile "path=$W/run/keyfiles"
check nm.unmanaged.all.but.the.client.and.the.tunnel nmv keyfile 'unmanaged-devices=except:interface-name:wlan2,except:interface-name:proton0,except:interface-name:pvpnksintrf0,except:interface-name:ipv6leakintrf0'
check nm.connectivity.off nmv connectivity 'enabled=false'
check nm.config.no.complaints test ! -s "$W/nm.perr"
# the user's side line, as read by NetworkManager
: > "$W/empty.conf"; mkdir -p "$W/userc"; sed -n '/^cat > "\$NMCONF" <<.EOT.$/,/^EOT$/p' "$RIGSRC/install.sh" | sed '1d;$d' > "$W/userc/90-lares-aerial-rig.conf"
NetworkManager --print-config --config="$W/empty.conf" --config-dir="$W/userc" --system-config-dir="$W/nms" --intern-config="$W/intern.conf" > "$W/nm2.print" 2> "$W/nm2.perr"
check nm.userline.parses bash -c 'grep -q "^\[device-lares-aerial-rig\]" "$1/nm2.print" && grep -q "^managed=0" "$1/nm2.print" && grep -q "^match-device=driver:mac80211_hwsim,interface-name:lrig-h" "$1/nm2.print" && [ ! -s "$1/nm2.perr" ]' _ "$W"

# the unit: systemd-analyze on a copy whose paths are moved to a stub dir
mkdir -p "$W/unit/lib"; printf '#!/bin/sh\nexit 0\n' > "$W/unit/lib/rig"; chmod +x "$W/unit/lib/rig"
sed "s|/usr/local/lib/lares/aerial-rig|$W/unit/lib|g" "$RIGSRC/lares-aerial-rig.service" > "$W/unit/lares-aerial-rig.service"
check unit.verify bash -c 'out=$(systemd-analyze verify "$1" 2>&1); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "$W/unit/lares-aerial-rig.service"
check unit.shape bash -c 'u=$1; grep -q "^Type=notify" "$u" && grep -q "^NotifyAccess=all" "$u" && grep -q "^ExecStopPost=.* cleanup$" "$u" && ! grep -q "^\[Install\]" "$u"' _ "$RIGSRC/lares-aerial-rig.service"

# hostapd is not installed: every key against the upstream hostapd.conf reference
check hostapd.keys.known bash -c '
    known=" interface bridge driver ctrl_interface ctrl_interface_group hw_mode channel ieee80211n ieee80211ac ieee80211d ieee80211w country_code ssid bss ignore_broadcast_ssid wpa wpa_key_mgmt rsn_pairwise auth_algs wpa_passphrase sae_password ieee8021x eap_server eap_user_file ca_cert server_cert private_key "
    for f in "$1"/conf/hostapd-a.conf "$1"/conf/hostapd-b.conf; do
        while IFS= read -r l; do
            case $l in "#"*|"") continue ;; "@COUNTRY@") continue ;; esac
            k=${l%%=*}; case $known in *" $k "*) ;; *) echo "$f: unknown key $k"; exit 1 ;; esac
        done < "$f"
    done' _ "$RIGSRC"
check hostapd.shape bash -c '
    a=$1/conf/hostapd-a.conf; b=$1/conf/hostapd-b.conf
    # the main interface of each file first, every other BSS after a bss= line, WPA2 networks always with a passphrase / SAE password / EAP file
    [ "$(grep -c "^ssid=" "$a")" = 3 ] && [ "$(grep -c "^ssid=" "$b")" = 3 ] && grep -q "^ignore_broadcast_ssid=1" "$a" \
      && grep -q "^wpa_key_mgmt=SAE" "$b" && grep -q "^ieee80211w=2" "$b" && grep -q "^wpa_key_mgmt=WPA-EAP" "$b" && grep -q "^eap_server=1" "$b" \
      && [ "$(grep -c "^ssid=rig-wpa2" "$a" "$b" | awk -F: "{s+=\$2} END {print s}")" = 2 ] \
      && [ "$(grep -h "^wpa_passphrase=" "$a" "$b" | grep -c rig-pass-wpa2)" = 2 ]' _ "$RIGSRC"
check eap.users.shape bash -c 'grep -q "^\*[[:space:]]*PEAP,TTLS" "$1/conf/eap_users" && grep -q "^\"rig-user\"[[:space:]]*MSCHAPV2,TTLS-MSCHAPV2[[:space:]]*\"rig-pass-eap\"[[:space:]]*\[2\]" "$1/conf/eap_users"' _ "$RIGSRC"

# every @PLACEHOLDER@ of a conf is filled by a sed expression of the rig (a missing one would leave "@VHT@" in a hostapd file)
check placeholders.filled bash -c '
    cd "$1"; for p in $(grep -oh "@[A-Z]*@" conf/* | sort -u); do
        [ "$p" = "@COUNTRY@" ] && { grep -q "/\^@COUNTRY@\\$/" rig || { echo "@COUNTRY@ not handled"; exit 1; }; continue; }
        grep -Eq "s[/|]$p[/|]" rig || { echo "$p is not substituted in rig"; exit 1; }
    done' _ "$RIGSRC"

# the radio-to-role mapping: the rig's own pipeline on an `iw dev` whose phys come in a scrambled order, with the real card first
check roles.by.phy.order bash -c '
    line=$(grep -F "mapfile -t ifs" "$1/rig"); [ -n "$line" ] || { echo "pipeline not found"; exit 1; }
    iw() { printf "phy#3\n\tInterface wlan7\n\t\tifindex 9\nphy#1\n\tInterface wlan5\nphy#4\n\tInterface wlan8\nphy#2\n\tInterface wlan6\n"; }
    ifs=(); eval "$line"; [ "${ifs[*]}" = "wlan5 wlan6 wlan7 wlan8" ] || { echo "got: ${ifs[*]}"; exit 1; }' _ "$RIGSRC"

# ---- the rig's laws, read from its text: the order and the guards --------------------------------------------------------------------
check rig.masks.before.networkmanager bash -c '
    f=$1/rig; m=$(grep -n "mount --bind .*/etc/resolv.conf" "$f" | head -1 | cut -d: -f1); r=$(grep -n "mount --bind \"\$RUN/rfkill-mask\" /dev/rfkill" "$f" | cut -d: -f1)
    n=$(grep -n "^    NetworkManager --no-daemon" "$f" | cut -d: -f1); d=$(grep -n "unshare --mount --uts" "$f" | head -1 | cut -d: -f1)
    [ -n "$m" ] && [ -n "$r" ] && [ -n "$n" ] && [ "$m" -lt "$n" ] && [ "$r" -lt "$n" ] && [ -n "$d" ]' _ "$RIGSRC"
check rig.inner.refuses.outside.the.netns bash -c 'grep -q "ip netns identify" "$1/rig" && [ "$(grep -n "ip netns identify" "$1/rig" | head -1 | cut -d: -f1)" -lt "$(grep -n "mount --bind" "$1/rig" | head -1 | cut -d: -f1)" ]' _ "$RIGSRC"
check rig.never.writes.the.real.resolv.conf bash -c '
    # every line that names /etc/resolv.conf is the bind mount or the check that it is bound; nothing else may name it
    bad=$(grep -n "/etc/resolv.conf" "$1/rig" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -v "mount --bind \"\$RUN/resolv.conf\" /etc/resolv.conf" | grep -v "stat -c %d:%i /etc/resolv.conf" | grep -v "log \"/etc/resolv.conf is not masked\"")
    [ -z "$bad" ] || { echo "$bad"; exit 1; }' _ "$RIGSRC"
check rig.rfkill.only.masked bash -c '
    bad=$(grep -n "rfkill" "$1/rig" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -v "/dev/rfkill" | grep -vE "(mkfifo -m 0600|exec 9<>) \"\\\$RUN/rfkill-mask\"$" )
    [ -z "$bad" ] || { echo "$bad"; exit 1; }' _ "$RIGSRC"
check rig.nm.reads.none.of.the.users bash -c '
    grep -q -- "--config=\"\$RUN/nm.conf\"" "$1/rig" && grep -q -- "--config-dir=\"\$RUN/nm-conf.d\"" "$1/rig" && grep -q -- "--system-config-dir=" "$1/rig" && grep -q -- "--intern-config=" "$1/rig" \
      && grep -q -- "--state-file=" "$1/rig" && grep -q "mount --bind \"\$RUN/nm-run\" /run/NetworkManager" "$1/rig" && grep -q "mount --bind \"\$RUN/nm-lib\" /var/lib/NetworkManager" "$1/rig"' _ "$RIGSRC"
check rig.prepare.cleans.on.failure bash -c 'grep -q "trap .*cleanup.*EXIT" "$1/rig" && grep -q "ExecStopPost=" "$1/lares-aerial-rig.service" && grep -q "hwsim-ours" "$1/rig"' _ "$RIGSRC"
check rig.portal.not.root bash -c 'grep -q "setpriv --reuid=\"\$USER_UID\".*portal.py" "$1/rig"' _ "$RIGSRC"
check rig.only.runs.root.owned.copies bash -c '! cat "$1/rig" "$1/lares-aerial-rig.service" | grep -vE "^[[:space:]]*#" | grep -E "\\\$HERE|tools/aerial|\.config/quickshell|/home/"' _ "$RIGSRC"

# ==================================================== the fake root ===================================================================
FR=$W/root
mkdir -p "$FR/etc/NetworkManager/conf.d" "$FR/etc/polkit-1/rules.d" "$FR/etc/systemd/system" "$FR/usr/local/lib"
printf '[main]\nplugins=keyfile\n' > "$FR/etc/NetworkManager/conf.d/00-user.conf"
printf '// the user'"'"'s own rule\n' > "$FR/etc/polkit-1/rules.d/50-user.rules"
mkdir -p "$W/bin"
for t in pacman systemctl nmcli; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$W" > "$W/bin/$t"; chmod +x "$W/bin/$t"
done
cat > "$W/bin/id" <<EOF
#!/bin/sh
[ "\$1" = -u ] && [ \$# = 1 ] && { echo 0; exit 0; }
exec /usr/bin/id "\$@"
EOF
chmod +x "$W/bin/id"

to_fake_root() {   # to_fake_root <script>: the script with /etc /usr /run /var after a space, = or " moved into the fake root, and root:root dropped
    # (a tab, a quote of another kind or a $(...) is NOT moved: such a line is refused below instead)
    sed -E -e "s#([ =\"])/(etc|usr|run|var)/#\1$FR/\2/#g" -e 's/ -o root -g root//' "$1"
}
paths_all_moved() {   # no line of the moved script (comments aside) still names a real /etc /usr /run /var /opt /home path
    local f=$1
    sed -e "s#$FR/#@FR@/#g" "$f" | grep -vE '^[[:space:]]*#' | grep -nE '(^|[^[:alnum:]_.$}/@-])/(etc|usr|run|var|opt|home)/' > "$W/refused.txt" && { cat "$W/refused.txt"; return 1; }
    return 0
}
real_before() { ls -la --time-style=+%s /etc/NetworkManager/conf.d /etc/polkit-1/rules.d /usr/local/lib/lares /etc/systemd/system/lares-aerial-rig.service /run/lares-rig 2> /dev/null | sha256sum; }
REAL0=$(real_before)

to_fake_root "$SRC/install.sh" > "$W/install.moved"; to_fake_root "$SRC/uninstall.sh" > "$W/uninstall.moved"
cp "$SRC/lares-aerial-rig.service" "$W/unit.copy"
paths_ok=1
check install.sh.paths.all.in.the.fake.root paths_all_moved "$W/install.moved" || paths_ok=0
check uninstall.sh.paths.all.in.the.fake.root paths_all_moved "$W/uninstall.moved" || paths_ok=0
if [ "$paths_ok" = 0 ]; then
    echo "(a line names a real path: nothing was run)"
else
    HERE_FAKE=$SRC    # the moved script finds its sources by its own dirname: put it beside them
    cp "$W/install.moved" "$SRC/.install.moved"; cp "$W/uninstall.moved" "$SRC/.uninstall.moved"
    run() { # run <script> <stdin> [env...]
        local s=$1 in=$2; shift 2
        printf '%s\n' "$in" | env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" "$@" bash "$s" > "$W/run.out" 2> "$W/run.err"
    }
    tree() { (cd "$FR" && find . -type f | sort | xargs -r sha256sum); }
    tree > "$W/tree.pristine"

    # refusals write nothing
    : > "$W/calls.log"
    run "$SRC/.install.moved" yes; rc1=$?
    run "$SRC/.install.moved" yes SUDO_USER=root; rc2=$?
    run "$SRC/.install.moved" yes 'SUDO_USER=bad"name'; rc3=$?
    run "$SRC/.install.moved" no SUDO_USER=testuser; rc4=$?
    check install.refusals.write.nothing bash -c '[ "$1" != 0 ] && [ "$2" != 0 ] && [ "$3" != 0 ] && [ "$4" != 0 ] && [ "$(cat "$5/tree.pristine")" = "$(cd "$6" && find . -type f | sort | xargs -r sha256sum)" ] && [ ! -s "$5/calls.log" ]' _ "$rc1" "$rc2" "$rc3" "$rc4" "$W" "$FR"

    # the install itself, twice
    run "$SRC/.install.moved" yes SUDO_USER=testuser; rc=$?
    check install.runs bash -c '[ "$1" = 0 ] || { cat "$2/run.err"; exit 1; }' _ "$rc" "$W"
    run "$SRC/.install.moved" yes SUDO_USER=testuser
    tree > "$W/tree.installed"
    L=$FR/usr/local/lib/lares/aerial-rig
    files_exactly() {
        local exp got
        exp=$({ printf '%s\n' ./etc/systemd/system/lares-aerial-rig.service ./etc/polkit-1/rules.d/49-lares-aerial-rig.rules \
                ./etc/NetworkManager/conf.d/90-lares-aerial-rig.conf ./usr/local/lib/lares/aerial-rig/{rig,portal.py,user} \
                ./etc/NetworkManager/conf.d/00-user.conf ./etc/polkit-1/rules.d/50-user.rules
              for f in "$RIGSRC"/conf/*; do echo "./usr/local/lib/lares/aerial-rig/conf/$(basename "$f")"; done; } | sort)
        got=$(cd "$FR" && find . -type f | sort)
        [ "$exp" = "$got" ] || { diff <(echo "$exp") <(echo "$got"); return 1; }
    }
    check install.files.exactly files_exactly
    check install.bytes.exact bash -c '
        L=$1; S=$2; cmp "$S/rig" "$L/rig" && cmp "$S/portal.py" "$L/portal.py" && cmp "$S/lares-aerial-rig.service" "$3/etc/systemd/system/lares-aerial-rig.service" \
          && for f in "$S"/conf/*; do cmp "$f" "$L/conf/$(basename "$f")" || exit 1; done && [ "$(cat "$L/user")" = testuser ]' _ "$L" "$RIGSRC" "$FR"
    check install.modes bash -c 'L=$1; [ "$(stat -c %a "$L/rig")" = 755 ] && for f in "$L/portal.py" "$L/user" "$L"/conf/* "$2/etc/systemd/system/lares-aerial-rig.service" "$2/etc/polkit-1/rules.d/49-lares-aerial-rig.rules" "$2/etc/NetworkManager/conf.d/90-lares-aerial-rig.conf"; do [ "$(stat -c %a "$f")" = 644 ] || { echo "$f"; exit 1; }; done' _ "$L" "$FR"
    check install.calls.exactly bash -c 'exp="pacman -S --needed hostapd dnsmasq wireless-regdb
systemctl daemon-reload
nmcli general reload conf"; got=$(sort -u "$1/calls.log" | sort); [ "$got" = "$(printf "%s\n" "$exp" | sort)" ] || { echo "$got"; exit 1; }; ! grep -q "start\|enable" "$1/calls.log"' _ "$W"
    check install.user.files.untouched bash -c '[ "$(grep -E "00-user|50-user" "$1/tree.pristine")" = "$(grep -E "00-user|50-user" "$1/tree.installed")" ] && [ -n "$(grep -E "00-user" "$1/tree.installed")" ]' _ "$W"
    check install.idempotent bash -c '[ "$(cat "$1/tree.installed")" = "$(cd "$2" && find . -type f | sort | xargs -r sha256sum)" ]' _ "$W" "$FR"
    # the polkit rule, evaluated with node: the user may start / stop / restart THIS unit and nothing else
    check polkit.rule.names.the.user grep -q 'subject.user == "testuser"' "$FR/etc/polkit-1/rules.d/49-lares-aerial-rig.rules"
    cat > "$W/rule_test.js" <<'JS'
const fs = require("fs");
let rule = null;
const polkit = { addRule: f => { rule = f; }, Result: { YES: "yes", NOT_HANDLED: "no" } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const ask = (user, unit, verb, id) => rule({ id: id || "org.freedesktop.systemd1.manage-units", lookup: k => ({ unit, verb })[k] }, { user }) || "no";
const out = [];
for (const v of ["start", "stop", "restart"]) out.push(ask("testuser", "lares-aerial-rig.service", v) === "yes");
out.push(ask("testuser", "lares-aerial-rig.service", "enable") === "no");
out.push(ask("testuser", "sshd.service", "start") === "no");
out.push(ask("mallory", "lares-aerial-rig.service", "start") === "no");
out.push(ask("", "lares-aerial-rig.service", "start") === "no");
out.push(ask("testuser", "lares-aerial-rig.service", "start", "org.freedesktop.login1.reboot") === "no");
console.log(out.join(" "));
process.exit(out.every(x => x) ? 0 : 1);
JS
    check polkit.rule.semantics node "$W/rule_test.js" "$FR/etc/polkit-1/rules.d/49-lares-aerial-rig.rules"
    check nmconf.line.exact bash -c 'cmp <(sed -n "/^cat > \"\$NMCONF\" <<.EOT.\$/,/^EOT\$/p" "$1/install.sh" | sed "1d;\$d") "$2/etc/NetworkManager/conf.d/90-lares-aerial-rig.conf"' _ "$RIGSRC" "$FR"

    # the uninstall, twice: everything the install made goes, the user's own files stay
    : > "$W/calls.log"
    run "$SRC/.uninstall.moved" ""; run "$SRC/.uninstall.moved" ""; rcu=$?
    check uninstall.runs bash -c '[ "$1" = 0 ] || { cat "$2/run.err"; exit 1; }' _ "$rcu" "$W"
    check uninstall.restores.the.tree bash -c '[ "$(cat "$1/tree.pristine")" = "$(cd "$2" && find . -type f | sort | xargs -r sha256sum)" ] && [ ! -e "$2/usr/local/lib/lares/aerial-rig" ]' _ "$W" "$FR"
    check uninstall.calls bash -c 'grep -q "^systemctl stop lares-aerial-rig.service" "$1/calls.log" && grep -q "^systemctl daemon-reload" "$1/calls.log" && grep -q "^nmcli general reload conf" "$1/calls.log" && ! grep -q "pacman" "$1/calls.log"' _ "$W"
fi
check the.real.machine.untouched bash -c '[ "$1" = "$2" ]' _ "$REAL0" "$(real_before)"

if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS"; else echo "$NAME RESULT FAIL"; fi
exit "$fail"
