#!/bin/sh
# A stand-in for tools/theme/themectl for a theme button test. It writes down how it was called ($TCB_LOG: `argv<TAB>...`,
# `pid<TAB>..`, `sid<TAB>..`) and behaves as $TCB_MODE says:
#   ok       themectl's ok lines, exit 0                       fail1   one FAIL line, exit 1        fail2   two FAIL lines, exit 2
#   refused  `themectl: refused: ...`, exit 100                 slow    an ok line, then sleeps 30 s (and writes `terminated` when it is told to stop)
{ printf 'argv'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "${TCB_LOG:-/dev/null}"
printf 'pid\t%s\n' "$$" >> "${TCB_LOG:-/dev/null}"
printf 'sid\t%s\n' "$(cut -d' ' -f6 /proc/$$/stat)" >> "${TCB_LOG:-/dev/null}"
trap 'echo terminated >> "${TCB_LOG:-/dev/null}"; exit 143' TERM
case "${TCB_MODE:-ok}" in
    ok)      echo "ok    lares        state.json: eva dark (changed)"; echo "ok    kitty        wrote /home/x/.config/kitty/current-theme.conf"; echo "themectl: eva dark: all ok"; exit 0 ;;
    fail1)   echo "ok    lares        state.json: eva dark (changed)"; echo "FAIL  hyprland     hyprctl eval: error: boom"; echo "themectl: eva dark: 1 FAIL"; exit 1 ;;
    fail2)   echo "FAIL  btop         cannot link /home/x/.config/btop/themes/current.theme: [Errno 13] Permission denied"; echo "ok    kitty        unchanged"; echo "FAIL  gtk          gsettings set org.gnome.desktop.interface gtk-theme: exit 1"; echo "themectl: eva dark: 2 FAIL"; exit 2 ;;
    refused) echo "themectl: refused: no theme named \"x\" (have: eva)"; exit 100 ;;
    slow)    echo "ok    lares        state.json: eva dark (changed)"; sleep 30 & wait $! ;;
esac
