#!/usr/bin/env bash

STATE_FILE="/tmp/hyproled_enabled"
SUSPEND_FILE="/tmp/hyproled_suspended"
DISABLED_FILE="/tmp/hyproled_disabled"
DIMENSIONS="6:46:2868:1568"
DIR="$HOME/.config/hypr/scripts/hyproled/hyproled-fixed.sh"

suspend_hyproled() {
    if [ -f "$STATE_FILE" ] && [ ! -f "$SUSPEND_FILE" ]; then
        touch "$SUSPEND_FILE"
        bash "$DIR" off
    fi
}

resume_hyproled() {
    if [ -f "$SUSPEND_FILE" ] && [ -f "$STATE_FILE" ]; then
        rm -f "$SUSPEND_FILE"
        bash "$DIR" -s -i -r 10 -a $DIMENSIONS > /dev/null
    fi
}

evaluate_hyproled() {
    # qs-shell deploy: if pidof hyprlock > /dev/null; then
    # qs-shell deploy BEGIN qslock: the Lares lock is a lock too (tools/lockscreen/lares-lock-held reads /proc/locks, takes nothing)
    if pidof hyprlock > /dev/null || /home/user/.local/state/lares/lock/current/tools/lockscreen/lares-lock-held "${XDG_RUNTIME_DIR:-/nonexistent}/lares-lock.lock" 2> /dev/null; then
    # qs-shell deploy END qslock
        suspend_hyproled
        return
    fi

    if hyprctl activewindow | grep -E -q '(fullscreen|fullscreenClient): [12]'; then
        suspend_hyproled
        return
    fi

    resume_hyproled
}

start_hyproled() {
    rm -f "$DISABLED_FILE"
    echo "on" > "$STATE_FILE"
    touch "$SUSPEND_FILE" 
    evaluate_hyproled
}

stop_hyproled() {
    touch "$DISABLED_FILE"
    rm -f "$STATE_FILE"
    rm -f "$SUSPEND_FILE"
    bash "$DIR" off
}

shift_hyproled() {
    if [ ! -f "$STATE_FILE" ]; then
        if [ ! -f "$DISABLED_FILE" ]; then
            start_hyproled
        fi
    elif [ -f "$STATE_FILE" ] && [ ! -f "$SUSPEND_FILE" ]; then
        bash "$DIR" -s -i -r 10 -a $DIMENSIONS > /dev/null
    fi
    status_hyproled
}

status_hyproled() {
    sleep 0.2
    if [ -f "$STATE_FILE" ]; then
        echo '{"alt":"enabled","class": "enabled","tooltip":"OLED Protection  -  Enabled "}'
    else
        echo '{"alt":"disabled","class": "disabled","tooltip":"OLED Protection  -  Disabled"}'
    fi
}

toggle_hyproled() {
    if [ -f "$STATE_FILE" ]; then
        stop_hyproled
    else
        start_hyproled &
    fi
}

case "$1" in
    toggle) toggle_hyproled ;;
    shift) shift_hyproled ;;
    status) status_hyproled ;;
    start) start_hyproled ;;
    stop) stop_hyproled ;;
    suspend) suspend_hyproled ;;
    resume) resume_hyproled ;;
    evaluate) evaluate_hyproled ;;
    *) echo "Usage: $0 {toggle|shift|status|start|stop|suspend|resume|evaluate}" ;;
esac