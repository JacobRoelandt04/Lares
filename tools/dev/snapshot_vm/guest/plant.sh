#!/bin/bash
# Fixtures for the rescue tests: files the restore must keep as they are, and trees with every kind of file the restore must bring back
# exactly (hardlinks, symlinks, device nodes, fifos, sparse files, xattrs, file capabilities, ACLs, ownership, setuid, odd names).
set -e
mk() { # the protected files of the contract, at version v1
    mkdir -p /usr/local/lib/lares/snapshot /etc/pacman.d/hooks /etc/lares /usr/share/polkit-1/actions /etc/polkit-1/rules.d /etc/grub.d
    echo "tool v1" > /usr/local/lib/lares/snapshot/lares-snapshot-root
    # real pacman reads every file in hooks/, so the stand-ins are valid hooks that never fire (their trigger names no package)
    for h in 00-lares-snapshot zz-lares-snapshot-done; do
        printf '[Trigger]\nOperation = Install\nType = Package\nTarget = lares-no-such-package\n\n[Action]\nDescription = v1 %s\nWhen = PostTransaction\nExec = /usr/bin/true\n' "$h" > /etc/pacman.d/hooks/$h.hook
    done
    echo "v1" > /etc/lares/marker
    echo "policy v1" > /usr/share/polkit-1/actions/org.lares.snapshot.policy
    echo "rule v1" > /etc/polkit-1/rules.d/50-lares-snapshot.rules
    echo "# crypttab v1" > /etc/crypttab
}
fixture() {
    local d=$1
    rm -rf "$d"; mkdir -p "$d/sub dir"
    echo "hello" > "$d/plain"
    ln "$d/plain" "$d/hardlink"
    ln -s plain "$d/symlink"
    ln -s /nonexistent/target "$d/dangling"
    mknod "$d/null" c 1 3
    mknod "$d/loop-ish" b 7 0
    mkfifo "$d/fifo"
    truncate -s 64M "$d/sparse"; printf 'tail' | dd of="$d/sparse" bs=1 seek=67108860 conv=notrunc 2>/dev/null; printf 'head' | dd of="$d/sparse" conv=notrunc 2>/dev/null
    echo "owned" > "$d/owned"; chown 1234:5678 "$d/owned"; chmod 640 "$d/owned"
    echo "suid" > "$d/suid"; chmod 4755 "$d/suid"
    echo "x" > "$d/xattr"; setfattr -n user.lares -v "value one" "$d/xattr"; setfattr -n trusted.lares -v "root only" "$d/xattr"
    cp /usr/bin/true "$d/cap"; setcap cap_net_raw+ep "$d/cap"
    echo "acl" > "$d/acl"; setfacl -m u:vmuser:r,g:wheel:rw "$d/acl"
    mkdir "$d/defacl"; setfacl -d -m u:vmuser:rwx "$d/defacl"
    echo "ünï çödé" > "$d/sub dir/ünï çödé ★.txt"
    touch -d '2020-02-02 02:02:02' "$d/plain"
}
mk
for d in /usr/local/share/lares-test /etc/lares-test /opt/lares-test /srv/lares-test /root/lares-test /var/lib/lares-test; do fixture "$d"; done
echo plant ok
