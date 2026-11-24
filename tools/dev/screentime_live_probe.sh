#!/usr/bin/env bash
# screentime_live_probe.sh -- READ-ONLY check of the installed screentimed on the real desktop.
#
#   tools/dev/screentime_live_probe.sh            # checks + today's away gaps and breaks
#   SECS=60 tools/dev/screentime_live_probe.sh    # also: wakeups and CPU over 60 s (default 0 = skip)
#   DAY=2026-10-07 tools/dev/screentime_live_probe.sh   # read another day's file
#
# It sends ONE query (`screentimed query state`) and reads /proc, the day file and the two
# installed hooks. It never feeds the daemon (no ctl, no lock-run): a fake `idle` here would
# cut real minutes out of the user's day.
#
# Checks (each `STLIVE <check> PASS|FAIL`, then `STLIVE RESULT PASS|FAIL`):
#   unit       screentimed.service is active
#   query      `query state` answers ok within 1 s
#   dropped    the daemon has dropped no malformed line
#   rss        resident memory < 3 MB
#   dayfile    the logical day's file exists
#   wrapper    ~/.local/bin/hyprlock runs hyprlock through `screentimed lock-run`
#   hypridle   hypridle.conf feeds sleep/wake/idle/active, has the 30 min listener that
#              ignores inhibitors (`ignore_inhibit = true` + `ctl idle 0`), and the running
#              hypridle started AFTER that file was last written (so it has read it)
# Printed for the desktop checklist (INSTALL.md §4), not judged:
#   the state's app / away / session / lastSession, every gap of 60 s or more between
#   intervals (an away: idle, lock or suspend), every break with its reason, and with SECS
#   the voluntary context switches and CPU ticks over the window.
set -u
cd "$(dirname "$0")/../.." || exit 1
SECS="${SECS:-0}"
fails=0
check() { # name ok detail
    if [ "$2" = 1 ]; then echo "STLIVE $1 PASS  $3"; else echo "STLIVE $1 FAIL  $3"; fails=$((fails + 1)); fi
}

if systemctl --user is-active --quiet screentimed; then check unit 1 "active"; else check unit 0 "$(systemctl --user is-active screentimed)"; fi
pid="$(systemctl --user show -p MainPID --value screentimed 2>/dev/null)"

state="$(timeout 1 screentimed query state 2>/dev/null)"
if [ -n "$state" ] && printf '%s' "$state" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)'; then
    check query 1 "answered"
else
    check query 0 "no answer"
    state='{"state":{}}'
fi

read -r dropped day <<<"$(printf '%s' "$state" | python3 -c '
import json, sys
s = json.load(sys.stdin).get("state", {})
print(s.get("dropped", -1), s.get("day", ""))')"
check dropped "$([ "$dropped" = 0 ] && echo 1 || echo 0)" "$dropped"

if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/status" ]; then
    rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")
    check rss "$([ "$rss" -lt 3072 ] && echo 1 || echo 0)" "${rss} kB"
else
    check rss 0 "no main pid"
fi

DAY="${DAY:-$day}"
dayfile="$HOME/.local/share/lares/screentime/days/${DAY%%-*}/$DAY.json"
check dayfile "$([ -f "$dayfile" ] && echo 1 || echo 0)" "$dayfile"

wrap="$HOME/.local/bin/hyprlock"
check wrapper "$(grep -q 'screentimed lock-run /usr/bin/hyprlock' "$wrap" 2>/dev/null && echo 1 || echo 0)" "$wrap"

conf="$HOME/.config/hypr/hypridle.conf"
feeds=0
for f in "ctl sleep" "ctl wake" "ctl idle 120" "ctl idle 0" "ctl active"; do grep -q "screentimed $f" "$conf" 2>/dev/null && feeds=$((feeds + 1)); done
grep -q "ignore_inhibit = true" "$conf" 2>/dev/null && feeds=$((feeds + 1))
hpid="$(pgrep -u "$(id -u)" -x hypridle | head -1)"
fresh=0
if [ -n "$hpid" ]; then
    started=$(( $(date +%s) - $(ps -o etimes= -p "$hpid" | tr -d ' ') ))
    [ "$started" -ge "$(stat -c %Y "$conf")" ] && fresh=1
fi
check hypridle "$([ "$feeds" = 6 ] && [ "$fresh" = 1 ] && echo 1 || echo 0)" "feeds $feeds/6, hypridle ${hpid:-absent}, started after the conf: $fresh"

# ---- for the checklist ------------------------------------------------------------------
printf '%s' "$state" | python3 -c '
import json, sys, time
s = json.load(sys.stdin).get("state", {})
def t(ms): return time.strftime("%H:%M:%S", time.localtime(ms / 1000)) if ms else "-"
print("state: app %s since %s, active %s, away %s since %s" % (s.get("app"), t(s.get("appSince")), s.get("active"), s.get("away"), t(s.get("awaySince"))))
ss = s.get("session") or {}
print("session: start %s, %s s active" % (t(ss.get("start")), ss.get("active")))
ls = s.get("lastSession")
if ls: print("lastSession: %s - %s, %s s active, ended by %s" % (t(ls.get("start")), t(ls.get("end")), ls.get("active"), ls.get("why")))
'
if [ -f "$dayfile" ]; then
    python3 - "$dayfile" <<'EOF'
import json, sys, time
d = json.load(open(sys.argv[1]))
def t(ms): return time.strftime("%H:%M:%S", time.localtime(ms / 1000))
iv = d["iv"]
print("day %s: %d intervals, total %s s" % (d["date"], len(iv), d["sum"]["total"]))
for a, b in zip(iv, iv[1:]):
    if b[0] - a[1] >= 60000:
        print("  gap %s - %s (%d s)" % (t(a[1]), t(b[0]), (b[0] - a[1]) // 1000))
for at, why in d["breaks"]:
    print("  break %s %s" % (t(at), why))
EOF
fi

if [ "$SECS" -gt 0 ] && [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; then
    v0=$(awk '/^voluntary_ctxt_switches:/ {print $2}' "/proc/$pid/status")
    c0=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    sleep "$SECS"
    v1=$(awk '/^voluntary_ctxt_switches:/ {print $2}' "/proc/$pid/status")
    c1=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    echo "over ${SECS} s: $((v1 - v0)) voluntary context switches, $((c1 - c0)) CPU ticks"
fi

echo "STLIVE RESULT $([ "$fails" = 0 ] && echo PASS || echo FAIL) ($fails failed)"
[ "$fails" = 0 ]
