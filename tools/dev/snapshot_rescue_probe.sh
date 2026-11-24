#!/usr/bin/env bash
# Checks of the Lares rescue that need no VM: syntax of every script, the GRUB fragment's output, the plan / guard logic of rescue.sh on a plain
# repository (busybox applets first on PATH, like the initramfs), the mkinitcpio build as a plain user and the image's contents and size.
#   tools/dev/snapshot_rescue_probe.sh            all of it
#   ARM=nofilter|noguard|nofont|autodetect  tools/dev/snapshot_rescue_probe.sh   one fault in a copy; the probe must say FAIL
# Needs: restic, mkinitcpio, a linux-lts kernel under /usr/lib/modules (the build part is skipped with a note when there is none).
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
repo=$(cd "$here/../.." && pwd)
src=$repo/tools/snapshot/root/rescue
BB=/usr/lib/initcpio/busybox
work=$(mktemp -d "${TMPDIR:-/tmp}/rescue-probe.XXXXXX")
trap '[ -n "${KEEPWORK:-}" ] || rm -rf "$work"' EXIT
fails=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
chk() { if ( eval "$2" ) >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

ARM=${ARM:-}
mkdir -p "$work/root"
rdir=$work/root/rescue
cp -r "$src" "$rdir"
cp "$src/../defaults.json" "$work/root/defaults.json"   # the install hook takes it from beside the rescue directory
cp "$src/../defaults.json" "$rdir/defaults.json"   # the image carries the root tool's defaults beside the menu
case $ARM in
    recordonly) sed -i 's/cat $T\/excl.rec $T\/excl.def | sort -u > $T\/excl/cp $T\/excl.rec $T\/excl/' "$rdir/rescue.sh" ;;
    noguard) sed -i 's|case \$p in "\$pre"\*) printf|case $p in "$pre"*) [ "$p" = /etc/lares ] \&\& continue; printf|' "$rdir/rescue.sh" ;;
    autodetect) sed -i "s/HOOKS=(base udev keymap keyboard block/HOOKS=(base udev autodetect keymap keyboard block/" "$rdir/mkinitcpio.conf" ;;
    nofilter) sed -i 's/lares-prime/zzz-prime/' "$rdir/rescue.sh" ;;
    "") ;;
    *) echo "unknown ARM $ARM"; exit 2 ;;
esac

echo "== syntax"
chk "rescue.sh parses in busybox ash" "$BB sh -n $rdir/rescue.sh"
chk "rescue.sh parses in sh" "sh -n $rdir/rescue.sh"
chk "runtime hook parses" "$BB sh -n $rdir/hooks/lares_rescue"
chk "45_lares_rescue parses" "sh -n $rdir/45_lares_rescue"
for f in build install-rescue.sh uninstall-rescue.sh install/lares_rescue; do chk "$f parses in bash" "bash -n $rdir/$f"; done

echo "== the GRUB fragment"
stub=$work/grub; mkdir -p "$stub" "$work/boot/lares"
cat > "$stub/grub-mkconfig_lib" <<'EOF'
# stand-in for grub-mkconfig_lib: the two functions the fragment uses
grub_probe=$STUB_GRUB_PROBE
make_system_path_relative_to_its_root() { echo "${1#/boot}"; }
EOF
cat > "$stub/grub-probe" <<'EOF'
#!/bin/sh
case "$*" in
    *fs_uuid*" /boot/"*|*fs_uuid*lares*) echo "${STUB_BOOT_UUID:-BOOT-1111}" ;;
    *fs_uuid*) echo "${STUB_ROOT_UUID:-aaaaaaaa-0000-0000-0000-000000000001}" ;;
    *--target=fs*) echo fat ;;
    *) echo part_gpt ;;
esac
EOF
chmod +x "$stub/grub-probe"
export STUB_GRUB_PROBE=$stub/grub-probe
frag() { pkgdatadir=$stub LARES_RESCUE_BOOT=$work/boot/lares sh "$rdir/45_lares_rescue"; }
chk "no output while the rescue image is missing" "[ -z \"\$(frag)\" ]"
: > "$work/boot/lares/rescue-vmlinuz"; : > "$work/boot/lares/rescue.img"
frag > "$work/frag.out"
chk "has the menu entry" "grep -q \"^menuentry 'Lares rescue'\" $work/frag.out"
chk "finds /boot by UUID (search --fs-uuid)" "grep -q 'search --no-floppy --fs-uuid --set=root' $work/frag.out"
chk "passes root=UUID= and lares.boot=UUID=" "grep -q 'root=UUID=aaaaaaaa' $work/frag.out && grep -q 'lares.boot=UUID=BOOT-1111' $work/frag.out"
chk "no resume= anywhere" "! grep -q 'resume=' $work/frag.out"
chk "no savedefault (GRUB_DEFAULT=saved is not moved)" "! grep -q savedefault $work/frag.out"
chk "the screen is the only console (a laptop with no UART must not lose its screen) and the big font is asked for" "grep -q 'console=tty0' $work/frag.out && ! grep -q 'ttyS0' $work/frag.out && grep -q 'fbcon=font:TER16x32' $work/frag.out"
STUB_ROOT_UUID=bbbbbbbb-1 STUB_BOOT_UUID=NEW-2222 frag > "$work/frag2.out"
chk "a changed UUID changes the entry (nothing is frozen into the image)" "grep -q 'root=UUID=bbbbbbbb-1' $work/frag2.out && grep -q 'search.*NEW-2222' $work/frag2.out"

echo "== plan, guards and the filtered list on a plain repository (busybox applets first)"
rt=$work/rt; mkdir -p "$rt/bin" "$rt/src/etc/lares" "$rt/src/etc/pacman.d/hooks" "$rt/src/usr/lib" "$rt/src/usr/local/lib/lares/snapshot" \
    "$rt/src/var/lib/ollama" "$rt/src/var/lib/pacman/local" "$rt/mnt/.lares-snapshots"
# the initramfs PATH: busybox applets and the programs the install hook adds (parsed from it), and nothing else
for a in $($BB --list); do [ "$a" = "[" ] || ln -sf "$BB" "$rt/bin/$a"; done
for b in restic $(sed -n 's/^    for b in \(.*\); do$/\1/p' "$rdir/install/lares_rescue" | head -n 1); do
    [ -x "$(command -v $b)" ] && ln -sf "$(command -v $b)" "$rt/bin/$b"
done
export RESTIC_PASSWORD=probe
echo probe > "$rt/mnt/.lares-snapshots/key"
echo a > "$rt/src/usr/lib/a"; echo b > "$rt/src/usr/lib/b"; echo hook > "$rt/src/etc/pacman.d/hooks/00-lares-snapshot.hook"
echo old > "$rt/src/etc/fstab"; echo l > "$rt/src/etc/lares/x"; echo old > "$rt/src/usr/local/lib/lares/snapshot/tool"
echo db > "$rt/src/var/lib/pacman/local/p"; echo big > "$rt/src/var/lib/ollama/m"; echo boot > "$rt/src/boot-file"
mkdir -p "$rt/src/boot"; echo kernel > "$rt/src/boot/vmlinuz-linux"
rrepo=$rt/mnt/.lares-snapshots/repo
restic -r "$rrepo" --password-file "$rt/mnt/.lares-snapshots/key" init -q >/dev/null 2>&1
(cd "$rt/src" && restic -r "$rrepo" --password-file "$rt/mnt/.lares-snapshots/key" backup -q . --tag lares --tag update >/dev/null 2>&1)
(cd "$rt/src" && restic -r "$rrepo" --password-file "$rt/mnt/.lares-snapshots/key" backup -q ./usr/lib/a --tag lares --tag lares-prime >/dev/null 2>&1)
sid=$(restic -r "$rrepo" --password-file "$rt/mnt/.lares-snapshots/key" snapshots --json --tag update | sed -n 's/.*"id":"\([0-9a-f]\{64\}\)".*/\1/p' | head -n 1)
# the state that is "broken": a changed file, an extra file, the kept files edited, an excluded tree with its own file
mnt=$rt/mnt; mkdir -p "$mnt/usr/lib" "$mnt/etc/lares" "$mnt/etc/pacman.d/hooks" "$mnt/usr/local/lib/lares/snapshot" "$mnt/var/lib/ollama" "$mnt/var/lib/pacman/local"
echo CHANGED > "$mnt/usr/lib/a"; echo extra > "$mnt/usr/lib/extra"; echo NEW > "$mnt/etc/fstab"; echo ext > "$mnt/etc/lares/ext"
echo NEWHOOK > "$mnt/etc/pacman.d/hooks/00-lares-snapshot.hook"; echo NEWTOOL > "$mnt/usr/local/lib/lares/snapshot/tool"
echo mine > "$mnt/var/lib/ollama/mine"; echo newpkg > "$mnt/var/lib/pacman/local/new"
cat > "$rt/plan.sh" <<EOF
export LARES_RESCUE_LIB=1 PATH=$rt/bin MNT=$mnt LS=$mnt/.lares-snapshots T=$rt/t ESP=$rt/esp LDIR=$rdir
. $rdir/rescue.sh
load_excludes $sid
make_plan $sid
echo "PLAN files=\$PLAN_FILES del=\$PLAN_DEL bytes=\$PLAN_BYTES trees=\$TREES bad=[\$PLAN_BAD] excl=\$EXCL_SRC boot=\$BOOT_FILES"
EOF
timeout -k 5 120 "$BB" sh "$rt/plan.sh" < /dev/null > "$work/plan.out" 2>&1
grep PLAN "$work/plan.out" || cat "$work/plan.out"
chk "plan: the changed and missing files are counted, the extra files are deletions" "grep -q 'PLAN files=3 del=2 ' $work/plan.out"
chk "plan: no kept path is touched (empty guard list)" "grep -q 'bad=\[\]' $work/plan.out"
chk "plan: with no record the built-in defaults are used, and it says so" "grep -q 'built-in defaults only' $work/plan.out"
chk "plan: the excluded trees and kept files are not planned for deletion" "! grep -q 'ollama\|lares' $rt/t/plan.var_lib $rt/t/plan.etc"
chk "plan: /boot files are listed (and never planned for deletion)" "grep -q 'boot=1 *$' $work/plan.out"
# a record with its own short list: the union with the defaults, never the record alone; an empty list falls back to the defaults too
mkdir -p "$mnt/.lares-snapshots/records"
short=$(echo "$sid" | cut -c1-8)
echo '{ "excludes": [ "/var/lib/foo" ] }' > "$mnt/.lares-snapshots/records/$short.json"
timeout -k 5 120 "$BB" sh "$rt/plan.sh" < /dev/null > "$work/plan2.out" 2>&1
chk "union: the record's /var/lib/foo AND the default /var/lib/ollama are kept" "grep -qx /var/lib/foo $rt/t/keep && grep -qx /var/lib/ollama $rt/t/keep && grep -q 'record and the built-in' $work/plan2.out"
echo '{ "excludes": [] }' > "$mnt/.lares-snapshots/records/$short.json"
timeout -k 5 120 "$BB" sh "$rt/plan.sh" < /dev/null > "$work/plan3.out" 2>&1
chk "an empty record list still keeps the defaults" "grep -qx /var/lib/ollama $rt/t/keep && grep -q 'built-in defaults only' $work/plan3.out"
rm -f "$mnt/.lares-snapshots/records/$short.json"
cat > "$rt/list.sh" <<EOF
export LARES_RESCUE_LIB=1 PATH=$rt/bin MNT=$mnt LS=$mnt/.lares-snapshots T=$rt/t2 ESP=$rt/esp LDIR=$rdir
mkdir -p \$T
. $rdir/rescue.sh
load_items
cat \$T/items
EOF
rm -f "$mnt/.lares-snapshots/index.tsv"
"$BB" sh "$rt/list.sh" > "$work/list.out" 2>&1
chk "fallback list: the update snapshot is there, with its time" "[ \$(grep -c . $work/list.out) = 1 ] && grep -q update $work/list.out"
chk "fallback list: the lares-prime snapshot is left out" "! grep -q prime $work/list.out && [ \$(grep -c . $work/list.out) = 1 ]"

echo "== the build as a plain user"
kv=$(ls /usr/lib/modules | grep lts | head -n 1)
if [ -z "$kv" ]; then
    echo "  skip no linux-lts under /usr/lib/modules"
else
    out=$work/out
    t0=$(date +%s)
    "$rdir/build" --out "$out" --no-grub --kernel "$kv" > "$work/build.out" 2>&1
    echo "  build took $(( $(date +%s) - t0 )) s: $(tail -n 1 "$work/build.out")"
    chk "rescue.img, rescue-vmlinuz and rescue.info exist" "[ -s $out/rescue.img ] && [ -s $out/rescue-vmlinuz ] && [ -s $out/rescue.info ]"
    chk "the kernel is a byte copy of the installed one" "cmp -s $out/rescue-vmlinuz /usr/lib/modules/$kv/vmlinuz"
    total=$(( ($(stat -c %s "$out/rescue.img") + $(stat -c %s "$out/rescue-vmlinuz")) / 1048576 ))
    chk "image and kernel together under 150 MB ($total MB)" "[ $total -lt 150 ]"
    lsinitcpio -a "$out/rescue.img" > "$work/lsa.out" 2>&1
    lsinitcpio "$out/rescue.img" > "$work/ls.out" 2>&1
    nmods=$(grep -c '\.ko' "$work/ls.out")
    chk "no autodetect hook: the config has none and the image carries every driver of the block and input trees ($nmods modules)" \
        "! grep '^HOOKS' $rdir/mkinitcpio.conf | grep -q autodetect && [ $nmods -gt 500 ]"
    chk "carries restic, e2fsck, mkswap, stty, date, setsid" "for b in restic e2fsck mkswap stty date setsid; do grep -q \"usr/bin/\$b\$\" $work/ls.out || exit 1; done"
    chk "has the keymap hook (the user's layout for the words typed)" "grep -q 'hooks/keymap' $work/ls.out"
    chk "carries the menu and the lists" "grep -q 'lares/rescue.sh' $work/ls.out && grep -q 'lares/protect.list' $work/ls.out && grep -q 'lares/defaults.json' $work/ls.out"
    # the console font file is optional (terminus-font may not be installed); the kernel's own TER16x32 is on the command line
    # a driver the kernel has built in needs no file; every other one must be in the image
    chk "has nvme, ahci, usb storage, usb keyboard, i8042, hid, ext4, vfat and nls (built in, or as a module in the image)" \
        "for m in nvme ahci usb-storage usbhid i8042 atkbd hid-generic xhci-pci ext4 vfat nls_cp437 nls_iso8859-1 nls_utf8; do grep -q \"/\$m\\.ko\" /usr/lib/modules/$kv/modules.builtin || grep -q \"/\$m\\.ko\" $work/ls.out || { echo missing \$m; exit 1; }; done"
    # drivers THIS machine does not load today (autodetect would drop them): another disk controller, a USB disk, a card reader
    chk "has drivers this machine does not use today: virtio_blk, ata_piix, uas, mmc_block (built in, or in the image)" \
        "for m in virtio_blk ata_piix uas mmc_block; do grep -q \"/\$m\\.ko\" /usr/lib/modules/$kv/modules.builtin || grep -q \"/\$m\\.ko\" $work/ls.out || { echo missing \$m; exit 1; }; done"
    chk "no resume hook in the image" "! grep -q 'hooks/resume\\|usr/lib/initcpio/hooks/resume' $work/ls.out"
    chk "the image is not named by any pacman preset" "! grep -rl rescue.img /etc/mkinitcpio.d/ 2>/dev/null | grep -q ."
fi

echo
if [ "$fails" = 0 ]; then echo "SNAPSHOT_RESCUE RESULT PASS"; else echo "SNAPSHOT_RESCUE RESULT FAIL ($fails checks failed)"; exit 1; fi
