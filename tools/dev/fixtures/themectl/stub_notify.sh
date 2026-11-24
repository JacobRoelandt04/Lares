#!/bin/sh
# A stand-in for notify-send: DesktopNotifier calls `notify-send -a APP -u URGENCY -t MS -p [-A id=label ...] -- TITLE BODY` and waits for it to
# print the daemon's id. This writes down the call ($TCB_NOTIFY_LOG: one line, TITLE<TAB>BODY with newlines as \n) and prints an id.
title=""; body=""; seen=0
for a in "$@"; do
    if [ "$seen" = 1 ]; then title="$a"; seen=2; continue; fi
    if [ "$seen" = 2 ]; then body="$a"; seen=3; continue; fi
    [ "$a" = "--" ] && seen=1
done
printf '%s\t%s\n' "$title" "$(printf '%s' "$body" | sed ':a;N;$!ba;s/\n/\\n/g')" >> "${TCB_NOTIFY_LOG:-/dev/null}"
echo 1
