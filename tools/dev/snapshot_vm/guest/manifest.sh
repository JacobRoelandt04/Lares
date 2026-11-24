#!/bin/bash
# manifest.sh OUT: everything a restore must reproduce, for the trees it restores, one sorted text file. Volatile paths are left out.
out=$1
{
  for t in /usr /etc /opt /srv /root /var/lib/pacman/local /var/lib/lares-test; do
    find "$t" -xdev \( -path /root/.cache -o -path /root/.bash_history -o -path /root/.lesshst -o -path /etc/resolv.conf -o -path /etc/ld.so.cache -o -path /etc/mtab -o -path /usr/share/info/dir -o -path /var/lib/lares-test/fifo.x \) -prune -o \
      -printf '%p\t%y\t%m\t%U:%G\t%s\t%l\t%T@\t%D:%i\n' 2>/dev/null
  done | awk -F'\t' -v OFS='\t' '{ if ($2=="d") $5=0; ino=$8; sub(/^[^:]*:/, "", ino); if ($2=="f" || $2=="l") { cnt[ino]++ } print }' | sort
  echo "--- sha256"
  for t in /usr /etc /opt /srv /root /var/lib/pacman/local /var/lib/lares-test; do
    find "$t" -xdev -type f \( -path /root/.cache -o -path /root/.bash_history -o -path /root/.lesshst -o -path /etc/resolv.conf -o -path /etc/ld.so.cache -o -path /usr/share/info/dir \) -prune -o -type f -print0 2>/dev/null | xargs -0 sha256sum 2>/dev/null
  done | sort -k2
  echo "--- xattr"
  getfattr -R -h -d -m - -e hex /usr/local/share/lares-test /etc/lares-test /opt/lares-test /srv/lares-test /root/lares-test /var/lib/lares-test /usr/bin/ping 2>/dev/null | sort
  echo "--- acl"
  getfacl -R -p /usr/local/share/lares-test /etc/lares-test /var/lib/lares-test 2>/dev/null | sort
  echo "--- hardlinks"
  find /usr /etc /var/lib/lares-test -xdev -type f -links +1 -printf '%i %p\n' 2>/dev/null | sort | awk '{ a[$1] = a[$1] " " $2 } END { for (i in a) print a[i] }' | sort
} | sed -E 's/^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([0-9]+)\.[0-9]+\t[^\t]*$/\1\t\2\t\3\t\4\t\5\t\6\t\7/' > "$out"
wc -l < "$out"
