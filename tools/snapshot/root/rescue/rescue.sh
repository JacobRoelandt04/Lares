#!/bin/sh
# The Lares rescue: runs in the rescue initramfs (busybox ash) before the system. A plain-text menu on the screen AND on the serial port;
# restores a restic snapshot of the root file system offline. Nothing of the root's /usr, /etc or /lib is used: every program is in this
# image (the root may be the thing that is broken). Contract: docs/contracts/snapshots.md. The root file system is checked, mounted
# read-only for the list and mounted read-write only when a restore is confirmed.

export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/tmp TMPDIR=/tmp RESTIC_PROGRESS_FPS=2
MNT=${MNT:-/mnt}
ESP=${ESP:-/esp}
LS=${LS:-$MNT/.lares-snapshots}
T=${T:-/tmp/lr}
LDIR=${LDIR:-/lares}
KEYS=$T/keys
mkdir -p $T $MNT $ESP
ROOT_UUID=; BOOT_UUID=; ROOT_DEV=; BOOT_DEV=; FSCK_OK=1; ESC=0; K=; N=0; LASTTTY=/dev/tty1; SERIAL=; ESP_SEPARATE=1; HIB_MOUNT=0

# The screen is /dev/tty1. The installed GRUB entry has `console=tty0` only: the last console= word makes /dev/console the serial port, and
# a laptop without a UART would show nothing. A serial port is used ONLY when the command line says lares.serial=ttyS0 (the test machine's copy of
# the entry): then everything is mirrored to it, and its keys are read too.
setup_console() {
    case " $(cat /proc/cmdline) " in *" lares.serial=ttyS0 "*) SERIAL=/dev/ttyS0 ;; esac
    if [ -n "$SERIAL" ]; then
        stty -F $SERIAL 115200 raw -echo clocal opost onlcr 2>/dev/null
        rm -f $T/out; mkfifo $T/out
        ( tee $SERIAL < $T/out > /dev/tty1 ) &
        exec > $T/out 2>&1 < /dev/null
    else
        exec > /dev/tty1 2>&1 < /dev/null
    fi
    # lares.debug=1: every command and error of the script goes to ttyS0 (for finding a fault on a machine with a serial port)
    case " $(cat /proc/cmdline) " in *" lares.debug=1 "*) stty -F /dev/ttyS0 115200 raw -echo clocal opost onlcr 2>/dev/null; exec 2>/dev/ttyS0; set -x ;; esac
}

# ---------------------------------------------------------------------------------------------------------------- screen
cls() { printf '\033[2J\033[H'; }
rev() { printf '\033[7m%s\033[0m\n' "$1"; }
say() { printf '%s\n' "$*"; }
pause_enter() { printf '%s' "${1:-Press Enter to continue.}"; while :; do key; [ "$K" = enter ] && break; done; printf '\n'; }

# A big font on a high-density screen: the kernel's 16x32 font is asked for on the command line; the console font is also set here
# when the framebuffer is wide (a 2880x1620 panel is unreadable at 8x16).
big_font() {
    local w
    w=$(sed 's/,.*//' /sys/class/graphics/fb0/virtual_size 2>/dev/null)
    [ -n "$w" ] && [ "$w" -ge 1800 ] 2>/dev/null && [ -f /lares/font.psf ] && setfont -C /dev/tty1 /lares/font.psf 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------------------------------------------- keys
# One reader per terminal (the screen's keyboard and the serial port) feeds one fifo with "<code in hex> <tty>"; `key` turns arrows
# into names. dd + xxd per key: it is slow and it does not matter, a person types it.
start_keys() {
    local t
    rm -f $KEYS; mkfifo $KEYS; exec 4<>$KEYS
    : > $T/keypids
    for t in /dev/tty1 $SERIAL; do
        [ -c $t ] || continue
        # clocal: opening a serial port with nobody on it must not wait for a carrier
        stty -F $t raw -echo clocal opost onlcr 2>/dev/null || continue
        (
            while :; do
                c=$(dd if=$t bs=1 count=1 2>/dev/null | xxd -p)
                [ -n "$c" ] && echo "$c $t" > $KEYS
            done
        ) &
        echo $! >> $T/keypids
    done
}
stop_keys() {
    local p
    for p in $(cat $T/keypids 2>/dev/null); do kill $p 2>/dev/null; done
    for t in /dev/tty1 $SERIAL; do [ -c $t ] && stty -F $t sane 2>/dev/null; done
    exec 4<&-
}
# sets K: up down enter esc bs ch (and N = the character code for ch)
key() {
    local h
    while :; do
        read -r h LASTTTY <&4
        N=$((0x$h))
        case $ESC in
            1) if [ $N = 91 ] || [ $N = 79 ]; then ESC=2; continue; fi; ESC=0; K=esc; return ;;
            2) ESC=0
               case $N in
                   65) K=up; return ;;
                   66) K=down; return ;;
                   53|54) ESC=3; continue ;;
                   *) continue ;;
               esac ;;
            3) ESC=0; continue ;;
        esac
        case $N in
            27) ESC=1 ;;
            13|10) K=enter; return ;;
            127|8) K=bs; return ;;
            *) K=ch; return ;;
        esac
    done
}
# reads a line (printable characters only) into LINE
readline() {
    LINE=
    while :; do
        key
        case $K in
            enter) printf '\n'; return ;;
            bs) [ -n "$LINE" ] && { LINE=${LINE%?}; printf '\b \b'; } ;;
            ch) if [ $N -ge 32 ] && [ $N -lt 127 ]; then
                    c=$(printf "\\$(printf %03o $N)")
                    LINE="$LINE$c"; printf '%s' "$c"
                fi ;;
        esac
    done
}

# ---------------------------------------------------------------------------------------------------------------- disks
parse_cmdline() {
    local w
    for w in $(cat /proc/cmdline); do
        case $w in
            root=UUID=*) ROOT_UUID=${w#root=UUID=} ;;
            lares.boot=UUID=*) BOOT_UUID=${w#lares.boot=UUID=} ;;
        esac
    done
}
wait_dev() {   # uuid -> device, waits up to 30 s for slow disks and USB
    local i=0 d
    while [ $i -lt 30 ]; do
        d=$(blkid -U "$1" 2>/dev/null) && [ -n "$d" ] && { echo "$d"; return 0; }
        i=$((i + 1)); sleep 1
    done
    return 1
}

check_root() {
    local rc
    say "Checking the root file system ($ROOT_DEV) ..."
    e2fsck -p "$ROOT_DEV" > $T/fsck.out 2>&1; rc=$?
    # 0 clean, 1 errors were corrected; 2 and up: it needs a person
    if [ $rc -ge 2 ]; then
        FSCK_OK=0
        say ""; say "The file system check could not repair the root file system (status $rc):"
        tail -n 12 $T/fsck.out
        say ""
    else
        FSCK_OK=1
        [ $rc = 1 ] && say "The check repaired small errors."
    fi
}

# ---------------------------------------------------------------------------------------------------------------- the list
RESTIC() { restic -r $LS/repo --password-file $LS/key --no-cache "$@"; }

# $T/items: <id> <epoch> <reason> <title>, newest first
load_items() {
    : > $T/items
    if [ -s $LS/index.tsv ]; then
        cp $LS/index.tsv $T/items
        return
    fi
    # No index (deleted or never written): ask restic. The warm-up snapshots (tag lares-prime) are no restore points.
    [ -d $LS/repo ] && [ -f $LS/key ] || return
    RESTIC snapshots --no-lock --json 2>/dev/null | sed 's/},{/}\n{/g' | grep '"id":"' > $T/snaps.json
    while read -r l; do
        case $l in *'"lares-prime"'*) continue ;; esac
        id=$(echo "$l" | sed -n 's/.*"id":"\([0-9a-f]\{64\}\)".*/\1/p')
        iso=$(echo "$l" | sed -n 's/^.*"time":"\([^"]*\)".*/\1/p')
        tags=$(echo "$l" | sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' | tr -d '"')
        reason=$(echo "$tags" | tr ',' '\n' | grep -v '^lares$' | head -n 1)
        ep=$(date -d "$iso" +%s 2>/dev/null)
        [ -n "$id" ] && [ -n "$ep" ] && printf '%s\t%s\t%s\t%s\n' "$id" "$ep" "${reason:-snapshot}" "Snapshot (no index)" >> $T/items.u
    done < $T/snaps.json
    [ -f $T/items.u ] && sort -t "$(printf '\t')" -k2,2 -rn $T/items.u > $T/items
}

fmt_time() { date -d "@$1" '+%d %b %Y %H:%M' 2>/dev/null || echo "$1"; }
human() {   # bytes -> text
    awk -v b="$1" 'BEGIN{ split("B KiB MiB GiB TiB",u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ }; f=(i==1 ? "%d %s" : "%.1f %s"); printf f, b, u[i] }'
}

# ---------------------------------------------------------------------------------------------------------------- menu
draw_menu() {   # $1 selected (1-based), $2 first shown
    local n total i line id ep reason title shown rows=14
    total=$(wc -l < $T/items)
    cls
    say "LARES RESCUE"
    say "Restore the system from a snapshot."
    say "Up / Down (or j / k) to choose, Enter to select."
    say ""
    if [ "$total" = 0 ]; then
        say "  No snapshots were found in /.lares-snapshots."
        say ""
    fi
    i=0; shown=0
    while IFS="$(printf '\t')" read -r id ep reason title; do
        i=$((i + 1))
        [ $i -lt $2 ] && continue
        [ $shown -ge $rows ] && break
        shown=$((shown + 1))
        line=$(printf '  %-17s %-7s %s' "$(fmt_time "$ep")" "$reason" "$title")
        [ $i = $1 ] && rev "$line" || say "$line"
    done < $T/items
    [ $2 -gt 1 ] && say "  ... earlier entries above"
    [ $((total - $2 + 1)) -gt $rows ] && say "  ... older snapshots below"
    say ""
    i=$((total + 1)); [ $1 = $i ] && rev "  Reboot" || say "  Reboot"
    i=$((total + 2)); [ $1 = $i ] && rev "  Shell" || say "  Shell"
    say ""
    [ "$FSCK_OK" = 0 ] && say "  The root file system has errors that could not be repaired."
    [ "$HIB_MOUNT" = 1 ] && say "  A hibernation image is stored on $(hib_devices | tr '\n' ' '): the disk was not checked and nothing is written until you choose a snapshot and discard it."
    say "  Root file system: $ROOT_DEV   (read-only until a restore is confirmed)"
}

menu() {
    local sel=1 first=1 total
    while :; do
        total=$(wc -l < $T/items)
        [ $sel -gt $((total + 2)) ] && sel=$((total + 2))
        # keep the selection on screen (14 rows)
        [ $sel -lt $first ] && first=$sel
        [ $sel -le $total ] && [ $sel -ge $((first + 14)) ] && first=$((sel - 13))
        [ $sel -gt $total ] && [ $first -lt $((total - 13)) ] && first=$((total > 13 ? total - 13 : 1))
        draw_menu $sel $first
        key
        case $K in
            up) [ $sel -gt 1 ] && sel=$((sel - 1)) ;;
            down) [ $sel -lt $((total + 2)) ] && sel=$((sel + 1)) ;;
            ch) case $N in 107) [ $sel -gt 1 ] && sel=$((sel - 1)) ;; 106) [ $sel -lt $((total + 2)) ] && sel=$((sel + 1)) ;; esac ;;
            enter)
                if [ $sel -le $total ]; then
                    PICK=$(sed -n "${sel}p" $T/items)
                    restore_flow "$PICK"
                elif [ $sel = $((total + 1)) ]; then
                    do_reboot
                else
                    do_shell
                fi ;;
        esac
    done
}

do_reboot() {
    cls; say "Rebooting ..."
    sync; [ "$ESP_SEPARATE" = 1 ] && umount $ESP 2>/dev/null; umount $MNT 2>/dev/null
    reboot -f
    sleep 60
}

do_shell() {
    local tty=$LASTTTY
    stop_keys
    cls; say "A shell. The root file system is at $MNT. Type exit to come back to the menu."
    setsid cttyhack sh < $tty > $tty 2>&1
    exec /bin/sh /lares/rescue.sh again
}

# ---------------------------------------------------------------------------------------------------------------- hibernation
# A swap partition that holds a hibernation image: the signature at byte 4086 is S1SUSPEND (kernel), S2SUSPEND or ULSUSPEND (uswsusp)
# instead of SWAPSPACE2. Writing the root file system under it and then resuming corrupts everything, so a restore refuses until the
# image is thrown away (the swap is made again with the same UUID and label, so fstab still finds it).
hib_devices() {
    local d n sig
    for d in /sys/class/block/*; do
        [ -f $d/partition ] || continue
        n=${d##*/}
        sig=$(dd if=/dev/$n bs=1 skip=4086 count=10 2>/dev/null | tr -cd '[:print:]')
        case $sig in S1SUSPEND*|S2SUSPEND*|ULSUSPEND*) echo /dev/$n ;; esac
    done
}
hib_check() {
    local d u l
    HIB=$(hib_devices)
    [ -z "$HIB" ] && return 0
    cls
    say "A hibernation image is stored on: $HIB"
    say ""
    say "The system was hibernated and not resumed. Restoring files under a hibernation image"
    say "and then resuming from it would corrupt the file system. The image must be discarded"
    say "first; whatever was open at that time is lost."
    say ""
    printf 'Type discard to throw the hibernation image away, or Enter to go back: '
    readline
    [ "$LINE" = discard ] || return 1
    for d in $HIB; do
        u=$(xxd -p -s 1036 -l 16 "$d" | tr -d '\n' | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
        l=$(dd if="$d" bs=1 skip=1052 count=16 2>/dev/null | tr -cd '[:print:]')
        say "Making the swap on $d again (uuid $u) ..."
        if [ -n "$l" ]; then mkswap -U "$u" -L "$l" "$d" >/dev/null 2>&1; else mkswap -U "$u" "$d" >/dev/null 2>&1; fi
        [ $? = 0 ] || { say "mkswap failed on $d."; pause_enter; return 1; }
    done
    return 0
}

# ---------------------------------------------------------------------------------------------------------------- /boot
# /boot is the ESP when the boot partition is another file system than the root; with /boot on the root file system (or no lares.boot) it is the
# root's own /boot directory. A separate one must mount (any file system type) BEFORE anything is written, or the restore refuses.
setup_esp() {
    if [ -z "$BOOT_UUID" ] || [ "$BOOT_UUID" = "$ROOT_UUID" ]; then ESP=$MNT/boot; ESP_SEPARATE=0; else ESP=${ESP:-/esp}; ESP_SEPARATE=1; fi
}
esp_check() {
    [ "$ESP_SEPARATE" = 1 ] || return 0
    mountpoint -q $ESP && return 0
    if [ ! -b "$BOOT_DEV" ]; then
        say "REFUSED: the boot partition ($BOOT_UUID) was not found, so /boot could not be restored. Nothing was changed."; return 1
    fi
    mkdir -p $ESP
    mount -o ro "$BOOT_DEV" $ESP 2>$T/esp.err || {
        say "REFUSED: the boot partition $BOOT_DEV could not be mounted, so /boot could not be restored. Nothing was changed."
        tail -n 2 $T/esp.err; return 1; }
    return 0
}

# ---------------------------------------------------------------------------------------------------------------- the snapshot's own lists
# Paths a restore keeps: the protect list, plus the excludes of the snapshot's record. The record is read from the repository's
# records/, else from the snapshot itself (var/lib/lares/snapshot-record.json), else the built-in defaults.
# The items of a JSON string list ("key": ["a", "b"]) one a line; the files are the tool's own (no nesting inside the lists)
json_list() { tr -d '\n' < "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep .; }
# a list of lines as a JSON array body: "a", "b"
json_num() { tr -d '\n' < "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }
jarr() { awk 'BEGIN { ORS = "" } { printf "%s\"%s\"", (NR > 1 ? ", " : ""), $0 }' "$1"; }

# What a restore leaves alone: the UNION of the snapshot's own exclude list (its record in the repository, else the record inside the
# snapshot) and the built-in defaults (defaults.json, in the image), so a record with a short or empty list can never make a restore delete
# /var/lib/ollama and the like; plus the protect list.
load_excludes() {   # $1 id
    local short rec
    short=$(echo "$1" | cut -c1-8)
    rec=$T/record.json
    rm -f $rec
    [ -f $LS/records/$short.json ] && cp $LS/records/$short.json $rec
    [ -s $rec ] || RESTIC dump --no-lock "$1" /var/lib/lares/snapshot-record.json > $rec 2>/dev/null
    json_list $LDIR/defaults.json excludes | grep '^/' > $T/excl.def
    : > $T/excl.rec
    [ -s $rec ] && json_list $rec excludes | grep '^/' > $T/excl.rec
    if [ -s $T/excl.rec ]; then
        EXCL_SRC="the snapshot's record and the built-in defaults"
    else
        EXCL_SRC="the built-in defaults only (the snapshot's record has no exclude list)"
    fi
    cat $T/excl.rec $T/excl.def | sort -u > $T/excl
    # ARM:noprotect (the line below is what a restore keeps as it is)
    grep '^/' $LDIR/protect.list > $T/prot
    cat $T/excl $T/prot > $T/keep
}

# restic --exclude arguments for tree $1 (usr, etc, var/lib ...): the kept paths below it, anchored to the tree's own root
tree_excludes() {
    local pre="/$1/" p
    while read -r p; do
        case $p in "$pre"*) printf -- '--exclude\n/%s\n' "${p#$pre}" ;; esac
    done < $T/keep
}

# A dot every two seconds while something without a progress line runs (the plan of a big tree on a slow disk): never a still screen.
busy() { ( while :; do sleep 2; printf '.'; done ) & BUSYPID=$!; }
busy_end() { kill $BUSYPID 2>/dev/null; wait $BUSYPID 2>/dev/null; printf '\n'; }

# ---------------------------------------------------------------------------------------------------------------- the plan
# The dry run: what each tree would change. Writes $T/plan.<tree> (restic's own lines) and totals into PLAN_*.
PLAN_FILES=0; PLAN_DEL=0; PLAN_BYTES=0; PLAN_BAD=
TREES=
make_plan() {   # $1 id
    local t args n rc sid=$1
    PLAN_FILES=0; PLAN_DEL=0; PLAN_BYTES=0; PLAN_BAD=; TREES=
    : > $T/bad
    local top; top=$(RESTIC ls --no-lock "$sid" / 2>/dev/null | sed 's|^/||')
    for t in usr opt etc srv root var/lib; do
        case $t in
            var/lib) RESTIC ls --no-lock "$sid" /var 2>/dev/null | grep -qx '/var/lib' || continue ;;
            *) echo "$top" | grep -qx "$t" || continue ;;
        esac
        TREES="$TREES $t"
        mkdir -p "$MNT/$t" 2>/dev/null
        tree_excludes "$t" > $T/exargs
        set --
        while read -r a; do set -- "$@" "$a"; done < $T/exargs
        printf '  planning /%s ' "$t"
        busy
        RESTIC restore --no-lock "$sid:/$t" --target "$MNT/$t" --delete --overwrite if-changed --dry-run -vv "$@" > "$T/plan.$(echo $t | tr / _)" 2>$T/plan.err
        rc=$?
        busy_end
        if [ $rc != 0 ]; then
            say "The plan for /$t failed:"; tail -n 5 $T/plan.err; return 1
        fi
        # totals, and every touched path that is on the keep list (a restore must never touch one)
        awk -v tree="/$t" -v mnt="$MNT" -v keepf=$T/keep '
            function bytes(n, u) { return n * (u=="KiB"?1024:u=="MiB"?1048576:u=="GiB"?1073741824:u=="TiB"?1099511627776:1) }
            BEGIN { while ((getline p < keepf) > 0) if (p != "") keep[++nk] = p }
            /^(updated|restored) .* with size / { f++; i = index($0, " with size "); sz = substr($0, i + 11); split(sz, a, " "); b += bytes(a[1], a[2]);
                p = $2; abs = tree p }
            /^deleted / { d++; abs = $2; sub("^" mnt, "", abs) }
            /^(updated|restored|deleted) / {
                if ($1 != "deleted" && abs == "") abs = tree $2
                for (k = 1; k <= nk; k++) if (abs == keep[k] || index(abs, keep[k] "/") == 1) { print $1 " " abs > "/dev/stderr"; break }
                abs = ""
            }
            END { printf "%d %d %.0f\n", f + 0, d + 0, b + 0 }' "$T/plan.$(echo $t | tr / _)" > $T/tot 2>> $T/bad
        read -r n d b < $T/tot
        PLAN_FILES=$((PLAN_FILES + n)); PLAN_DEL=$((PLAN_DEL + d)); PLAN_BYTES=$((PLAN_BYTES + b))
    done
    # /boot: regular files only, nothing is ever deleted there
    RESTIC ls --no-lock "$sid" /boot > $T/bootlist 2>/dev/null
    BOOT_FILES=$(grep -c '^/boot/' $T/bootlist)
    [ -s $T/bad ] && PLAN_BAD=$(head -n 5 $T/bad)
    return 0
}

# ---------------------------------------------------------------------------------------------------------------- progress
# Reads restic's --json lines on stdin and redraws ONE line in place: percent, bytes, speed and the time left. The last line (the
# summary) is kept in $T/last.json. A slow SSD (30 MB/s) makes a restore minutes long: the line must always move.
show_progress() {   # $1 label
    awk -v label="$1" '
        function fld(s, k,   r) { if (match(s, "\"" k "\":[-0-9.e+]+")) { r = substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return r + 0 } return -1 }
        function hum(b,   i, u) { split("B KiB MiB GiB TiB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } return sprintf((i == 1 ? "%d %s" : "%.1f %s"), b, u[i]) }
        { last = $0 }
        /"message_type":"status"/ {
            pct = fld($0, "percent_done"); tot = fld($0, "total_bytes"); done = fld($0, "bytes_restored"); if (done < 0) done = fld($0, "bytes_done")
            el = fld($0, "seconds_elapsed")
            if (tot > 0 && done >= 0) {
                sp = (el > 0) ? done / el : 0
                eta = (sp > 0) ? (tot - done) / sp : -1
                line = sprintf("  %-14s %3d%%  %s of %s", label, (pct >= 0 ? pct * 100 : done * 100 / tot), hum(done), hum(tot))
                if (sp > 0) line = line sprintf("  %s/s", hum(sp))
                if (eta >= 0) line = line sprintf("  %d:%02d left", eta / 60, eta % 60)
            } else line = sprintf("  %-14s working ...", label)
            printf "\r%-78s", line; fflush()
        }
        END { printf "\r%-78s\r", ""; print last > "'$T'/last.json"; fflush() }'
}

# ---------------------------------------------------------------------------------------------------------------- the safety snapshot
safety_snapshot() {   # $1 id being restored; prints the new short id in SAFE
    local avail now host rc bin rcdir id short added packed files bytes secs
    SAFE=
    avail=$(df -k $MNT | awk 'NR==2 { print $4 }')
    if [ "${avail:-0}" -lt 4194304 ]; then
        say "There is less than 4 GB free on the root file system: a safety copy of the current state is skipped."
        return 0
    fi
    say "Taking a safety snapshot of the current state ..."
    # a prune or backup that died with the machine leaves a lock; from here the host name differs and restic would wait it out. Nobody else can be using this repository.
    RESTIC unlock --remove-all >/dev/null 2>&1
    local st0=$(date +%s)
    bin=$MNT/.lares-snapshots/.rescue-bin
    rm -rf "$bin"; mkdir -p "$bin"
    # restic must see the root's own paths (/usr, /etc ...), so it runs inside a chroot of the root with its libraries copied there
    cp /usr/bin/restic "$bin/restic"
    cp -a /usr/lib/ld-linux-x86-64.so.2 /usr/lib/lib*.so* "$bin/" 2>/dev/null
    if [ "$ESP_SEPARATE" = 1 ]; then mkdir -p $MNT/boot; mount --bind $ESP $MNT/boot 2>/dev/null; fi
    : > $T/bpaths
    json_list $LDIR/defaults.json paths | grep '^/' > $T/cpaths
    while read -r p; do [ -d "$MNT$p" ] && echo "$p" >> $T/bpaths; done < $T/cpaths
    for f in $ESP/*; do [ -f "$f" ] && echo "/boot/${f##*/}" >> $T/bpaths; done
    host=$(cat $MNT/etc/hostname 2>/dev/null); [ -n "$host" ] || host=$(RESTIC snapshots --no-lock --json --latest 1 2>/dev/null | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p' | head -n 1)
    now=$(date +%s)
    mkdir -p $MNT/var/lib/lares
    printf '{ "version": 1, "reason": "rescue", "time": %s, "note": "taken by the rescue before a restore" }\n' "$now" > $MNT/var/lib/lares/snapshot-record.json
    set --
    while read -r e; do set -- "$@" --exclude "$e"; done < $T/excl
    ( chroot $MNT "/.lares-snapshots/.rescue-bin/ld-linux-x86-64.so.2" --library-path /.lares-snapshots/.rescue-bin \
        /.lares-snapshots/.rescue-bin/restic -r /.lares-snapshots/repo --password-file /.lares-snapshots/key --no-cache \
        backup --one-file-system --pack-size 64 --read-concurrency 8 --json --tag lares --tag rescue --group-by host \
        ${host:+--host "$host"} "$@" $(cat $T/bpaths | tr '\n' ' ') ; echo $? > $T/rc ) 2>$T/err | show_progress "Safety copy"
    rc=$(cat $T/rc 2>/dev/null)
    [ "$ESP_SEPARATE" = 1 ] && umount $MNT/boot 2>/dev/null
    rm -rf "$bin"
    if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
        say "The safety snapshot failed (status ${rc:-?}):"; tail -n 5 $T/err
        return 1
    fi
    id=$(sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p' $T/last.json | head -n 1)
    [ -n "$id" ] || { say "The safety snapshot did not report an id."; return 1; }
    short=$(echo "$id" | cut -c1-8)
    added=$(sed -n 's/.*"data_added":\([0-9]*\).*/\1/p' $T/last.json | head -n 1)
    packed=$(sed -n 's/.*"data_added_packed":\([0-9]*\).*/\1/p' $T/last.json | head -n 1)
    files=$(sed -n 's/.*"total_files_processed":\([0-9]*\).*/\1/p' $T/last.json | head -n 1)
    bytes=$(sed -n 's/.*"total_bytes_processed":\([0-9]*\).*/\1/p' $T/last.json | head -n 1)
    secs=$(sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p' $T/last.json | head -n 1)
    # the record and the index line, written like the tool writes them (temp file, then rename)
    mkdir -p $LS/records
    JPATHS=$(jarr $T/cpaths); JEXC=$(jarr $T/excl)
    printf '{ "version": 1, "id": "%s", "short": "%s", "time": %s, "reason": "rescue", "run": null, "count": 0, "critical": [], "targets": [], "before": {}, "changed": null, "state": "done", "keep": false, "note": "", "added": %s, "addedPacked": %s, "files": %s, "bytes": %s, "seconds": %s, "paths": [%s], "excludes": [%s], "kernel": "rescue" }\n' \
        "$id" "$short" "$now" "${added:-0}" "${packed:-0}" "${files:-0}" "${bytes:-0}" "${secs:-0}" "$JPATHS" "$JEXC" > $LS/records/$short.json.new
    mv $LS/records/$short.json.new $LS/records/$short.json
    { printf '%s\t%s\trescue\tBefore the restore of %s\n' "$id" "$now" "$(date -d "@$now" '+%d %b %Y')"; cat $LS/index.tsv 2>/dev/null; } > $LS/index.tsv.new
    mv $LS/index.tsv.new $LS/index.tsv
    sync   # the record and the index line must survive a power cut in the middle of the restore
    SAFE=$short
    say "Safety snapshot $short is saved (it is in the list now) in $(( $(date +%s) - st0 )) s."
    return 0
}

# ---------------------------------------------------------------------------------------------------------------- the restore
do_trees() {   # $1 id
    local t n=0 total rc lab sid=$1
    total=$(echo $TREES | wc -w)
    for t in $TREES; do
        n=$((n + 1))
        tree_excludes "$t" > $T/exargs
        set --
        while read -r a; do set -- "$@" "$a"; done < $T/exargs
        lab="/$t ($n/$total)"
        ( RESTIC restore "$sid:/$t" --target "$MNT/$t" --delete --overwrite always --sparse --no-lock --json "$@" ; echo $? > $T/rc ) 2>$T/err | show_progress "$lab"
        rc=$(cat $T/rc)
        if [ "$rc" != 0 ]; then say "Restoring /$t failed (status $rc):"; tail -n 5 $T/err; return 1; fi
        b=$(sed -n 's/.*"bytes_restored":\([0-9]*\).*/\1/p' $T/last.json | tail -n 1)
        WRITTEN=$((WRITTEN + ${b:-0}))
        say "  /$t restored."
    done
    return 0
}

# /boot LAST and gently: nothing in the ESP is deleted, and nothing but the files the snapshot holds is written. Each file is written
# BESIDE the old one, flushed, read back and compared with the snapshot's copy, and only then renamed over the old one.
do_boot() {   # $1 id
    local stage=$LS/boot-stage f name bad=0 rc
    [ -s $T/bootlist ] || { say "  The snapshot holds no files for /boot."; return 0; }
    rm -rf "$stage"; mkdir -p "$stage"
    rm -f $ESP/.*.lares-new 2>/dev/null
    printf '  Reading /boot files from the snapshot '
    busy
    RESTIC restore --no-lock "$1:/boot" --target "$stage" --verify > $T/bootrestore.out 2>&1; rc=$?
    busy_end
    [ $rc = 0 ] || { say "Reading /boot from the snapshot failed:"; tail -n 4 $T/bootrestore.out; return 1; }
    for f in "$stage"/*; do
        [ -f "$f" ] || continue
        name=${f##*/}
        if [ -f "$ESP/$name" ] && cmp -s "$f" "$ESP/$name"; then continue; fi
        say "  /boot/$name"
        if ! cp "$f" "$ESP/.$name.lares-new"; then say "  Could not write beside /boot/$name (no room?)."; bad=1; break; fi
    done
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    if [ $bad = 0 ]; then
        for f in "$stage"/*; do
            [ -f "$f" ] || continue
            name=${f##*/}
            [ -f "$ESP/.$name.lares-new" ] || continue
            if ! cmp -s "$f" "$ESP/.$name.lares-new"; then say "  /boot/$name was not written correctly."; bad=1; break; fi
        done
    fi
    if [ $bad = 0 ]; then
        for f in "$stage"/*; do
            [ -f "$f" ] || continue
            name=${f##*/}
            [ -f "$ESP/.$name.lares-new" ] && mv -f "$ESP/.$name.lares-new" "$ESP/$name"
        done
        sync
    else
        rm -f $ESP/.*.lares-new 2>/dev/null
    fi
    rm -rf "$stage"
    [ $bad = 0 ]
}

restore_flow() {   # $1 = "<id> <epoch> <reason> <title>" (tab separated)
    local id ep reason title ans
    IFS="$(printf '\t')" read -r id ep reason title <<EOF
$1
EOF
    hib_check || return
    if [ "$HIB_MOUNT" = 1 ]; then
        # the image is gone: now the root may be checked (that writes), then read again
        umount $MNT 2>/dev/null
        check_root
        mount -o ro "$ROOT_DEV" $MNT 2>$T/mnt.err || { say "The root file system could not be mounted:"; cat $T/mnt.err; pause_enter; return; }
        HIB_MOUNT=0; load_items
    fi
    cls
    say "Snapshot: $(fmt_time "$ep")  $reason  $title"
    say ""
    esp_check || { pause_enter; return; }
    say "Reading the snapshot ..."
    load_excludes "$id"
    if ! make_plan "$id"; then pause_enter; return; fi
    say ""
    say "This restore would change:"
    say "  files to write : about $PLAN_FILES (about $(human $PLAN_BYTES))"
    say "                   every file is read and compared, only what differs is written"
    say "  files to delete: $PLAN_DEL"
    UNR=$(json_num $T/record.json unreadable)
    [ "${UNR:-0}" -gt 0 ] 2>/dev/null && { say "  NOTE: $UNR files could not be read when the snapshot was made."; say "        They are not in it, so this restore deletes them."; }
    say "  /boot files    : $BOOT_FILES (compared first, only changed ones are written)"
    say "  kept as they are now: $(grep -c . $T/keep) paths (the Lares tool, fstab, ...)"
    say "  excluded trees come from $EXCL_SRC"
    if [ -n "$PLAN_BAD" ]; then
        say ""
        say "REFUSED: this restore would touch paths that must stay as they are:"
        echo "$PLAN_BAD" | sed 's/^/  /'
        say "Nothing was changed."
        pause_enter; return
    fi
    if [ "$FSCK_OK" = 0 ]; then
        say ""
        say "The root file system has errors that were not repaired. Type force to restore anyway."
        printf '> '; readline
        [ "$LINE" = force ] || return
    fi
    say ""
    printf 'Type yes to restore this snapshot, or Enter to go back: '
    readline
    [ "$LINE" = yes ] || return

    # ---- writing starts here
    mount -o remount,rw $MNT 2>/dev/null || { say "The root file system could not be mounted read-write."; pause_enter; return; }
    mkdir -p $ESP
    [ "$ESP_SEPARATE" = 1 ] && { mount -o remount,rw $ESP 2>/dev/null || { say "The boot partition could not be mounted read-write."; mount -o remount,ro $MNT 2>/dev/null; pause_enter; return; }; }
    WRITTEN=0
    if ! safety_snapshot "$id"; then
        say ""; printf 'Type go on to restore without the safety snapshot, or Enter to stop: '; readline
        [ "$LINE" = "go on" ] || { mount -o remount,ro $MNT 2>/dev/null; return; }
    fi
    local t0=$(date +%s)
    say ""
    say "Restoring ..."
    if ! do_trees "$id"; then say ""; say "The restore stopped. Nothing in /boot was changed. Run it again (it continues)."; pause_enter; return; fi
    say "  Restoring /boot ..."
    if ! do_boot "$id"; then say "The files in /boot could not be restored; the old ones are in place. Run it again."; pause_enter; return; fi
    sync
    say ""
    say "Restored $(fmt_time "$ep") ($reason) in $(( $(date +%s) - t0 )) s; $(human $WRITTEN) written."
    [ -n "$SERIAL" ] && say "RESCUE-DONE written=$WRITTEN"
    [ "$ESP_SEPARATE" = 1 ] && umount $ESP 2>/dev/null; umount $MNT 2>/dev/null
    sync
    pause_enter "Restored. Press Enter to reboot."
    reboot -f
    sleep 60
}

# ---------------------------------------------------------------------------------------------------------------- start
main() {
    parse_cmdline
    setup_console
    # the kernel's own messages are quieted so they do not scribble on the menu
    case " $(cat /proc/cmdline) " in *" lares.debug=1 "*) echo 7 > /proc/sys/kernel/printk ;; *) echo 1 > /proc/sys/kernel/printk 2>/dev/null ;; esac
    cls
    say "LARES RESCUE  starting ..."
    big_font
    ROOT_DEV=$(wait_dev "$ROOT_UUID") || { say "The root file system ($ROOT_UUID) was not found."; do_shell; }
    [ -n "$BOOT_UUID" ] && BOOT_DEV=$(wait_dev "$BOOT_UUID")
    setup_esp
    start_keys
    open_root
    export TZ=:$MNT/etc/localtime
    load_items
    menu
}

# A hibernation image comes FIRST: no check, no journal replay (even a read-only mount replays it), nothing written until it is discarded.
open_root() {
    HIB=$(hib_devices)
    if [ -n "$HIB" ]; then   # ARM:hibfirst
        HIB_MOUNT=1
        mount -o ro,noload "$ROOT_DEV" $MNT 2>$T/mnt.err
    else
        check_root
        mount -o ro "$ROOT_DEV" $MNT 2>$T/mnt.err
    fi || { say "The root file system could not be mounted:"; cat $T/mnt.err; pause_enter; do_shell; }
}

[ -n "$LARES_RESCUE_LIB" ] && return 0 2>/dev/null
case $1 in
    again) parse_cmdline; setup_console; ROOT_DEV=$(blkid -U "$ROOT_UUID"); BOOT_DEV=$(blkid -U "$BOOT_UUID" 2>/dev/null); setup_esp; start_keys
           mountpoint -q $MNT || open_root; export TZ=:$MNT/etc/localtime; load_items; menu ;;
    *) main ;;
esac
# main never returns; if the script is ever ended by an error, give a shell instead of letting init die (a kernel panic)
say "The rescue stopped unexpectedly. A shell follows; reboot with: reboot -f"
exec setsid cttyhack sh
