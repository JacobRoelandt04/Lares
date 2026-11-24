#!/usr/bin/env bash
# install.sh -- install (or remove) silicon's root helper. The user runs it with sudo.
#
#   cargo build --release            (as yourself; this script never runs cargo, never as root)
#   sudo ./install.sh                install
#   sudo ./install.sh --uninstall    remove exactly what install put there, and nothing else
#   ./install.sh --dry-run           say what would happen, for the current user; changes
#   ./install.sh --uninstall --dry-run   nothing and needs no root (it still reads, e.g.
#                                    /var/lib/silicon/mux.json, to tell you what it found)
#
# What it installs (every path below is the whole list):
#   /usr/local/libexec/silicon-helper                        the binary, root:root 0755
#   /usr/share/polkit-1/actions/org.lares.silicon.helper.policy
#       the polkit action for THAT binary (defaults: auth_admin)
#   /etc/polkit-1/rules.d/50-lares-silicon-helper.rules
#       YES, without a prompt, for SUDO_USER only, on the active local session, for THAT action only
#   /etc/systemd/system/silicon-boot.service        records the firmware's power limits, applies the boot profile
#   /etc/systemd/system/silicon-mux.service         applies a queued GPU MUX change at shutdown
#   /etc/systemd/system/silicon-mux-guard.service   checks a MUX change after the reboot, reverts an unconfirmed one
#   /var/lib/silicon/                                       the helper's state (root, 0755)
# After installing it runs `silicon-helper record-caps` once: it records the firmware's power limits for this
# boot and applies nothing, so a re-install in the middle of a session never re-applies the stored boot profile.
# It does NOT touch asusd, asusctl or asus-boot-quiet.service: they keep running; silicon-boot
# is ordered after them (and after powertop.service, whose --auto-tune rewrites the EPP), so at
# boot silicon's values are the last word. Retiring asusctl is a
# separate, later checklist.
set -euo pipefail
set -f                                 # no globbing, anywhere
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 022

BIN_DST=/usr/local/libexec/silicon-helper
LIBEXEC_DIR=/usr/local/libexec
POLICY_DST=/usr/share/polkit-1/actions/org.lares.silicon.helper.policy
RULE_DST=/etc/polkit-1/rules.d/50-lares-silicon-helper.rules
UNIT_DIR=/etc/systemd/system
UNITS=(silicon-boot.service silicon-mux.service silicon-mux-guard.service)
STATE_DIR=/var/lib/silicon
STATE_FILES=(firmware_caps.json boot.json mux.json boot_applied.json .lock .firmware_caps.json.tmp .boot.json.tmp .mux.json.tmp .boot_applied.json.tmp)

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_SRC="$HERE/target/release/silicon-helper"
POLICY_SRC="$HERE/polkit/org.lares.silicon.helper.policy"
RULE_SRC="$HERE/polkit/50-lares-silicon-helper.rules.in"

DRY=0
UNINSTALL=0
TMP_RULE=""
trap 'if [[ -n $TMP_RULE ]]; then rm -f -- "$TMP_RULE"; fi' EXIT

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
install.sh -- install (or remove) silicon's root helper. The user runs it with sudo.

  cargo build --release              (as yourself; this script never runs cargo, never as root)
  sudo ./install.sh                  install
  sudo ./install.sh --uninstall      remove exactly what install put there, and nothing else
  ./install.sh --dry-run             say what would happen, for the current user; changes nothing,
  ./install.sh --uninstall --dry-run needs no root (it still READS, e.g. /var/lib/silicon/mux.json)
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'install.sh: unknown argument: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

# ---- who the rule is for -------------------------------------------------------------------
# A real run: root, via sudo, from a non-root account. A dry run: whoever runs it.
if [[ $DRY -eq 1 ]]; then
    if [[ $EUID -eq 0 && ( -z ${SUDO_USER:-} || ${SUDO_USER:-} == root ) ]]; then
        say "would REFUSE: running as root without sudo from your own account (SUDO_USER is empty or root)"
        exit 1
    fi
    TARGET_USER="${SUDO_USER:-$(id -un)}"
else
    [[ $EUID -eq 0 ]] || die "run it with sudo:  sudo $0 $*"
    [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]] || die "run it with sudo from your own account (SUDO_USER is empty or root)"
    TARGET_USER="$SUDO_USER"
fi
[[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "user name '$TARGET_USER' is not a plain login name"
TARGET_UID="$(id -u -- "$TARGET_USER" 2>/dev/null)" || die "no such user: $TARGET_USER"
[[ $TARGET_UID -ne 0 ]] || die "refusing to grant the helper to root"

# ---- doing things (or saying so) -----------------------------------------------------------
run() {
    if [[ $DRY -eq 1 ]]; then
        printf 'would run:'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}
# like run, but a failure is not fatal (stopping or disabling what may not be there)
try() {
    if [[ $DRY -eq 1 ]]; then
        printf 'would run (failure ignored):'; printf ' %q' "$@"; printf '\n'
    else
        "$@" || true
    fi
}

render_rule() {  # the rule, for TARGET_USER (a validated login name: no quote can be in it)
    local text
    text="$(<"$RULE_SRC")"
    printf '%s\n' "${text//@USER@/$TARGET_USER}"
}

# ---- uninstall -----------------------------------------------------------------------------
uninstall() {
    say "silicon-helper: uninstall (dry run: $DRY)"
    # A MUX change in flight is guarded by the guard unit: do not take the guard away.
    if [[ -r $STATE_DIR/mux.json ]] && grep -Eq '"state":"(applied|awaiting-keep)"' "$STATE_DIR/mux.json"; then
        die "a GPU mode change is in flight ($STATE_DIR/mux.json says applied or awaiting-keep): the guard must stay until it is confirmed or reverted. Confirm it in the shell, or wait for the revert and reboot, then run this again. (If the record is stale, remove $STATE_DIR/mux.json yourself.)"
    fi
    try systemctl stop silicon-mux-guard.service silicon-boot.service silicon-mux.service
    try systemctl disable silicon-boot.service silicon-mux.service silicon-mux-guard.service
    local u f
    for u in "${UNITS[@]}"; do run rm -f -- "$UNIT_DIR/$u"; done
    run rm -f -- "$RULE_DST" "$POLICY_DST" "$BIN_DST"
    try systemctl daemon-reload
    try systemctl reset-failed silicon-boot.service silicon-mux.service silicon-mux-guard.service
    for f in "${STATE_FILES[@]}"; do run rm -f -- "$STATE_DIR/$f"; done
    try rmdir -- "$STATE_DIR"
    try rmdir -- "$LIBEXEC_DIR"
    say
    say "$([[ $DRY -eq 1 ]] && echo 'would be removed' || echo removed): $BIN_DST, $POLICY_DST, $RULE_DST, ${UNITS[*]} (in $UNIT_DIR), and the helper's state files."
    say "left alone: asusd, asusctl, asus-boot-quiet.service, and anything else in $STATE_DIR or $LIBEXEC_DIR."
    say "(The firmware keeps whatever GPU MUX setting it holds; CPU and charge settings persist until the next reboot or change.)"
}

# ---- install -------------------------------------------------------------------------------
install_all() {
    say "silicon-helper: install for user $TARGET_USER (dry run: $DRY)"
    [[ -f $BIN_SRC && -x $BIN_SRC ]] || die "$BIN_SRC is missing: build it first, as yourself:  (cd '$HERE' && cargo build --release)"
    [[ "$(head -c 4 -- "$BIN_SRC")" == $'\x7f'ELF ]] || die "$BIN_SRC is not an ELF executable"
    # a build older than its sources is not this tree's helper (2026-11-07: an Oct 7 build was installed over the Nov 6 fix)
    local newer
    newer=$(find "$HERE/src" "$HERE/Cargo.toml" "$HERE/Cargo.lock" -type f -newer "$BIN_SRC" -print -quit 2> /dev/null || true)
    [[ -z $newer ]] || die "$BIN_SRC is older than $newer: rebuild it first, as yourself:  (cd '$HERE' && cargo build --release)"
    local f
    for f in "$POLICY_SRC" "$RULE_SRC" "$HERE/units/silicon-boot.service" "$HERE/units/silicon-mux.service" "$HERE/units/silicon-mux-guard.service"; do
        [[ -f $f ]] || die "$f is missing"
    done
    [[ -d /usr/share/polkit-1/actions && -d /etc/polkit-1/rules.d ]] || die "polkit is not installed (no /usr/share/polkit-1/actions or /etc/polkit-1/rules.d)"
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found: this needs systemd"

    run install -d -m 0755 -o root -g root -- "$LIBEXEC_DIR"
    run install -m 0755 -o root -g root -- "$BIN_SRC" "$BIN_DST"
    run install -d -m 0755 -o root -g root -- "$STATE_DIR"
    run install -m 0644 -o root -g root -- "$POLICY_SRC" "$POLICY_DST"
    if [[ $DRY -eq 1 ]]; then
        say "would write $RULE_DST (root:root 0644) with this content:"
        render_rule | sed 's/^/    | /'
    else
        TMP_RULE="$(mktemp)"
        render_rule > "$TMP_RULE"
        install -m 0644 -o root -g root -- "$TMP_RULE" "$RULE_DST"
        rm -f -- "$TMP_RULE"
        TMP_RULE=""
    fi
    local u
    for u in "${UNITS[@]}"; do run install -m 0644 -o root -g root -- "$HERE/units/$u" "$UNIT_DIR/$u"; done
    run systemctl daemon-reload
    run systemctl enable silicon-boot.service silicon-mux-guard.service
    # the MUX unit must be ACTIVE for its ExecStop to run at the first shutdown: start it now
    run systemctl enable --now silicon-mux.service
    # Records the firmware's power limits for this boot, and NOTHING else. (boot-apply is silicon-boot.service's job at
    # boot: run here, on a re-install with a boot set already stored, it would re-apply that boot profile over the one
    # the user is using.)
    if [[ $DRY -eq 1 ]]; then
        say "would run (failure reported, not fatal): $BIN_DST record-caps"
        say "would run, as $TARGET_USER: $BIN_DST status   (must answer \"ok\":true)"
    else
        "$BIN_DST" record-caps || say "WARNING: record-caps exited with $? (see above). The helper is installed; run  sudo $BIN_DST record-caps  again."
        local answer=""
        if command -v runuser >/dev/null 2>&1; then answer="$(runuser -u "$TARGET_USER" -- "$BIN_DST" status 2>/dev/null || true)"; fi
        if [[ $answer == *'"ok":true'* ]]; then
            say "status as $TARGET_USER: ok"
        else
            say "WARNING: '$BIN_DST status' as $TARGET_USER did not answer ok."
        fi
    fi
    say
    say "$([[ $DRY -eq 1 ]] && echo 'would be installed' || echo installed): $BIN_DST, $POLICY_DST, $RULE_DST, ${UNITS[*]} (in $UNIT_DIR), $STATE_DIR"
    say "verify without a password prompt, as $TARGET_USER:  pkexec $BIN_DST apply     (a no-op that must print {\"ok\":true,...})"
    say "the stored boot profile is applied at boot by silicon-boot.service; this install applied nothing (record-caps only records the firmware's limits)."
    say "undo:  sudo '$HERE/install.sh' --uninstall"
    say "asusd, asusctl and asus-boot-quiet.service are untouched and keep running; silicon-boot runs after them."
}

if [[ $UNINSTALL -eq 1 ]]; then uninstall; else install_all; fi
