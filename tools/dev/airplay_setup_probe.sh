#!/usr/bin/env bash
# airplay_setup_probe.sh -- `lares setup`'s row for silicon's wifi-powersave verb (R4), on a FAKE ROOT with stub helpers, and the
# printed root step run AS PRINTED (sudo is a stub that adds --dry-run to install.sh, cargo a stub that leaves an ELF: nothing is
# installed, nothing is built, no real root path is touched).
#
#   tools/dev/airplay_setup_probe.sh              AIRPLAY_SETUP RESULT PASS | FAIL
#   ARM=alwaysin   the row calls any helper "has the verb"          -> "a helper without the verb is TO DO"
#   ARM=badline    the printed step has no build in front of install -> "the printed step, run as printed"
#
# A copy of the tool and of helpers/silicon_helper is the code under test (an arm patches that copy only). `lares setup` reads the
# machine as it is (read only); HOME, the runtime dir and the root prefix are the probe's own.
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO0=$PWD
W="$(mktemp -d "${SCRATCH:-/tmp}/aps.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/rt" "$W/stubs" "$W/repo/tools/shell" "$W/repo/helpers"
chmod 700 "$W/rt"
cp -p tools/shell/lares "$W/repo/tools/shell/lares"
for f in tools/shell/*; do [ -f "$f" ] && [ ! -e "$W/repo/$f" ] && cp -p "$f" "$W/repo/$f"; done
rsync -a --exclude target helpers/silicon_helper "$W/repo/helpers/"
case "${ARM:-}" in
    "") ;;
    alwaysin) grep -q 'grep -q .\"wifi-powersave\".' "$W/repo/tools/shell/lares" || { echo "ARM anchor gone"; exit 3; }
        sed -i "s|grep -q '\"wifi-powersave\"'|cat > /dev/null|" "$W/repo/tools/shell/lares" ;;
    badline) grep -q "(cd '\$h' && cargo build --release) && sudo" "$W/repo/tools/shell/lares" || { echo "ARM anchor gone"; exit 3; }
        sed -i "s|(cd '\$h' \&\& cargo build --release) \&\& sudo '\$h/install.sh'|sudo '\$h/install.sh'|" "$W/repo/tools/shell/lares" ;;
    *) echo "unknown ARM=${ARM:-}"; exit 2 ;;
esac
# the stubs: a sudo that only dry-runs, a cargo that leaves a fresh ELF, in front of the machine's PATH
cat > "$W/stubs/sudo" <<'STUB'
#!/bin/sh
exec "$@" --dry-run
STUB
cat > "$W/stubs/cargo" <<'STUB'
#!/bin/sh
mkdir -p target/release && printf '\177ELF\002\001\001\000' > target/release/silicon-helper && chmod +x target/release/silicon-helper
STUB
chmod +x "$W/stubs/"*
run_setup() {   # run_setup <name> : lares setup against the root prefix $W/root-<name>
    env -i PATH="$W/stubs:/usr/bin:/bin" HOME="$W/home" XDG_RUNTIME_DIR="$W/rt" LARES_ROOT_PREFIX="$W/root-$1" LARES_REPO="$W/repo" \
        timeout 90 "$W/repo/tools/shell/lares" setup > "$W/$1.out" 2>&1
}
helper() {   # helper <name> old|new|none
    local d="$W/root-$1/usr/local/libexec"
    mkdir -p "$d"
    case "$2" in
        old) printf '#!/bin/sh\necho "{\\"ok\\":false,\\"proto\\":1,\\"why\\":\\"unknown command %s\\"}" "$1"\nexit 2\n' > "$d/silicon-helper" ;;
        new) printf '#!/bin/sh\necho "{\\"ok\\":true,\\"proto\\":1,\\"verbs\\":[\\"status\\",\\"apply\\",\\"wifi-powersave\\",\\"capabilities\\"]}"\n' > "$d/silicon-helper" ;;
        none) return ;;
    esac
    chmod +x "$d/silicon-helper"
}
BAD=0
check() { local what=$1; shift; if "$@" > /dev/null 2>&1; then echo "APS ok   $what"; else echo "APS FAIL $what" | tee -a "$W/fails"; BAD=$((BAD + 1)); fi; }
helper old old; helper new new; helper none none; mkdir -p "$W/root-none"
for n in old new none; do run_setup "$n"; done
check "a helper without the verb is TO DO, and the R4 step is printed" bash -c 'grep -aqE "^  TO DO +R4 Wi-Fi power save verb" "$1" && grep -aq "^R4  SILICON.S WI-FI POWER SAVE" "$1"' _ "$W/old.out"
check "a helper with the verb is ok, and no R4 step is printed" bash -c 'grep -aqE "^  ok +R4 Wi-Fi power save verb.*has wifi-powersave" "$1" && ! grep -aq "^R4  " "$1"' _ "$W/new.out"
check "no helper installed: ok, nothing to do" bash -c 'grep -aqE "^  ok +R4 Wi-Fi power save verb.*not installed" "$1" && ! grep -aq "^R4  " "$1"' _ "$W/none.out"
check "the printed step builds as you and installs with sudo, from the helper folder" bash -c 'grep -aqE "^      \(cd .*/helpers/silicon_helper. && cargo build --release\) && sudo .*/helpers/silicon_helper/install.sh.$" "$1"' _ "$W/old.out"
# (R4's own lines: R6, the interaction boost, prints the same rebuild line for a helper that lacks its verb too)
sed -n '/^R4  /,/^R[0-9][0-9]*  /p' "$W/old.out" | grep -aE '^      \(cd .*cargo build' | sed 's/^ *//' > "$W/step.sh"
check "the printed step, run as printed (sudo a dry-run stub, cargo a stub): the install it would make is the helper's" bash -c '
    [ "$(wc -l < "$1")" -eq 1 ] && ! grep -q "/usr/local\|/etc/" "$1" &&
    out=$(PATH="'"$W"'/stubs:$PATH" SUDO_USER=$(id -un) bash "$1" 2>&1) &&
    printf "%s\n" "$out" | grep -q "^would run: install -m 0755 -o root -g root -- .*/target/release/silicon-helper /usr/local/libexec/silicon-helper$" &&
    printf "%s\n" "$out" | grep -q "^would run:.*install -m 0644 .*/polkit/org.lares.silicon.helper.policy"' _ "$W/step.sh"
check "the step's own check line names the verb" bash -c 'grep -aq "silicon-helper capabilities  *# must list \"wifi-powersave\"" "$1"' _ "$W/old.out"
if [ -n "${ARM:-}" ]; then
    case "$ARM" in alwaysin) needle="a helper without the verb is TO DO" ;; badline) needle="the printed step" ;; esac
    if grep -aq "^APS FAIL .*$needle" "$W/fails" 2> /dev/null; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
if [ "$BAD" -eq 0 ]; then echo "AIRPLAY_SETUP RESULT PASS"; exit 0; fi
KEEP=1; echo "AIRPLAY_SETUP RESULT FAIL ($BAD red: $W)"; exit 1
