#!/usr/bin/env bash
# An isolated Hyprland for the lockscreen's tests: nothing appears on the
# user's screen and nothing of theirs is touched.
#
#   tools/dev/lock_env.sh up          start it   (env: LOCK_ENV name, OUTPUTS 1|2,
#                                 LOCKED_CMD "cmd" for Hyprland --locked-cmd,
#                                 MODE light|dark, ANIMATIONS true|false,
#                                 LOCK_REFRESH 60|120 = LOCK-1's refresh rate (default 60),
#                                 AUTOSTART "cmd" run at hyprland.start,
#                                 XRAY_STATIC true = the unsafe config, for ARMs,
#                                 HOST=window: a nested WINDOW on the user's
#                                 desktop instead of headless -- hands-on only)
#   tools/dev/lock_env.sh run CMD...  run CMD inside it (a Wayland client of it)
#   tools/dev/lock_env.sh hyprctl ARGS...
#   tools/dev/lock_env.sh shot FILE.png [OUTPUT]   grim of the whole layout / one output
#   tools/dev/lock_env.sh type TEXT   /  key KEYSYM...   keyboard via wtype
#   tools/dev/lock_env.sh point "abs X Y W H" click ...  the virtual pointer
#   tools/dev/lock_env.sh status      /  down
#
# HOW. Hyprland 0.56 only runs NESTED (its DRM backend needs the seat the real
# session holds), and its Wayland backend needs a host offering xdg_wm_base v6:
# sway 1.12 offers 5 and aborts it. The host is a HEADLESS mutter (installed
# with GNOME; xdg_wm_base v7), which never shows a window anywhere. Mutter
# never configures Hyprland's window output either, so the outputs the tests
# use are Hyprland's own HEADLESS ones (LOCK-1, LOCK-2), created at start.
#
# ISOLATION. Everything lives in /tmp/lrlk-<name> (short: socket paths end at
# 108 bytes): a private XDG_RUNTIME_DIR (Wayland sockets, Hyprland's instance,
# quickshell's by-id dirs), private config/state/cache/data homes (the theme
# state is seeded here, never the user's), and a private session bus with NO
# service directories (nothing is D-Bus-activated). The environment is built
# with `env -i`, so the user's WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE
# and DISPLAY never reach a test process. Hyprland gets
# HYPRLAND_NO_SD_VARS=1 (no export into the user's systemd environment),
# LIBSEAT_BACKEND=seatd at a missing socket (its DRM attempt fails at once
# instead of asking logind for the user's session), Xwayland off (it would
# bind /tmp/.X11-unix). EGL is pinned to Mesa so the NVIDIA GPU of a hybrid laptop is not woken; a machine whose only GPU is
# NVIDIA's has nothing for Mesa to drive (mutter segfaults, 2026-11-22) and takes NVIDIA's own (egl_env).
# Core dumps are off: a lock's core would hold a password buffer.
#
# CLEANUP. Every process started here carries LOCK_ENV_DIR=<dir> in its
# environment -- the lock that Hyprland spawns inherits it -- so `down` kills
# exactly those, found through /proc/<pid>/environ, and never anything of the
# user's. `down` also compares the user's systemd environment with the copy
# taken at `up` and prints LOCK_ENV USERENV CHANGED if anything leaked.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${LOCK_ENV:-lk0}"
B="/tmp/lrlk-$NAME"
BUSCONF="$ROOT/tools/dev/fixtures/notifications/dbus-session.conf"
MESA_EGL=/usr/share/glvnd/egl_vendor.d/50_mesa.json
NVIDIA_EGL=/usr/share/glvnd/egl_vendor.d/10_nvidia.json

die() { echo "lock_env: $*" >&2; exit 1; }

# No core dumps from anything started here: a lock's core would hold a
# password buffer, and systemd-coredump keeps it (measured: a SEGV'd probe
# lock was stored while only `up` had the limit).
ulimit -c 0

# Pids of processes that belong to this environment, by the env marker.
env_pids() {
    local p
    for p in /proc/[0-9]*; do
        [ -O "$p" ] || continue
        { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "LOCK_ENV_DIR=$B" && echo "${p#/proc/}"
    done
}

mutter_argv() {
    # The host mutter's argv. mutter 51 (2026-10-16) in --headless mode opens the first DRM render node
    # udev lists -- on this laptop the NVIDIA one -- before the boot GPU, gets no renderer with EGL pinned
    # to Mesa and segfaults (cogl_renderer_is_hardware_accelerated; found by stream Z2). Under bwrap it
    # sees only the nodes of a GPU Mesa drives ("Boot VGA GPU /dev/dri/renderD128 selected as primary"). That was the boot_vga GPU
    # until the MUX: in dGPU-only the NVIDIA card IS boot_vga (2026-11-15) and the same segfault came back, so the GPU is picked by
    # its DRIVER (anything but nvidia), the boot_vga one first.
    # --die-with-parent: killing bwrap (cmd_down) never leaves a mutter behind.
    local n d drv want args=()
    if command -v bwrap > /dev/null 2>&1 && [ "$(ls /dev/dri/renderD* 2> /dev/null | wc -l)" -gt 1 ]; then
        for want in 1 0; do
            for n in /sys/class/drm/card[0-9]* /sys/class/drm/renderD[0-9]*; do
                case "$n" in *-*) continue ;; esac
                drv=$(basename "$(readlink -f "$n/device/driver" 2> /dev/null)")
                [ "$drv" = nvidia ] && continue
                [ "$(cat "$n/device/boot_vga" 2> /dev/null)" = "$want" ] || continue
                d="/dev/dri/${n##*/}"
                [ -e "$d" ] && args+=(--dev-bind "$d" "$d")
            done
            [ ${#args[@]} -gt 0 ] && break
        done
        if [ ${#args[@]} -gt 0 ]; then
            echo bwrap --die-with-parent --dev-bind / / --tmpfs /dev/dri "${args[@]}" -- mutter
            return
        fi
    fi
    echo mutter
}
# The EGL vendor of everything started here: NVIDIA's where every render node is the nvidia driver's, else Mesa's.
egl_env() {
    local d all=""
    for d in /sys/class/drm/renderD[0-9]*; do
        [ -e "$d" ] || continue
        all=nvidia
        [ "$(basename "$(readlink -f "$d/device/driver" 2> /dev/null)")" = nvidia ] || { all=mesa; break; }
    done
    if [ "$all" = nvidia ] && [ -f "$NVIDIA_EGL" ]; then
        echo __EGL_VENDOR_LIBRARY_FILENAMES="$NVIDIA_EGL" __GLX_VENDOR_LIBRARY_NAME=nvidia
    else
        echo __EGL_VENDOR_LIBRARY_FILENAMES="$MESA_EGL" __GLX_VENDOR_LIBRARY_NAME=mesa
    fi
}
base_env() {
    # The one environment every process of this env starts from.
    local bus; bus=$(cat "$B/bus.addr" 2>/dev/null)
    echo HOME="$HOME" PATH="$PATH" USER="$USER" LANG="${LANG:-C.UTF-8}" \
         XDG_RUNTIME_DIR="$B/rt" XDG_CONFIG_HOME="$B/cfg" XDG_STATE_HOME="$B/state" \
         XDG_CACHE_HOME="$B/cache" XDG_DATA_HOME="$B/data" \
         DBUS_SESSION_BUS_ADDRESS="$bus" LARES_TEST_BUS=1 LOCK_ENV_DIR="$B" $(egl_env)
}

hypr_sig() { ls "$B/rt/hypr" 2>/dev/null | head -1; }

client_env() {
    # What a Wayland client of the nested Hyprland sees.
    echo $(base_env) WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE="$(hypr_sig)" \
         QT_QPA_PLATFORM=wayland QS_ICON_THEME="${QS_ICON_THEME:-Papirus}"
}

cmd_up() {
    [ -e "$B/up" ] && die "$NAME is already up ($B); run down first"
    rm -rf "$B"
    mkdir -p "$B/rt" "$B/cfg/theme" "$B/state" "$B/cache" "$B/data" || die "mkdir"
    chmod 700 "$B/rt"
    printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$B/cfg/theme/state.json"
    systemctl --user show-environment > "$B/userenv.before" 2>/dev/null

    dbus-daemon --config-file="$BUSCONF" --fork --print-address=3 --print-pid=4 \
        3> "$B/bus.addr" 4> "$B/bus.pid" || die "dbus-daemon"
    # The bus has no LOCK_ENV_DIR marker (dbus-daemon clears nothing, but it
    # was not started under env -i): it is killed by its recorded pid.

    local outputs="${OUTPUTS:-1}" mons="" creates=""
    mons='hl.monitor({ output = "WAYLAND-1", disabled = true })'$'\n''hl.monitor({ output = "LOCK-1", mode = "2880x1620@'"${LOCK_REFRESH:-60}"'", position = "0x0", scale = 1 })'
    creates='    hl.exec_cmd("hyprctl output create headless LOCK-1")'
    if [ "${HOST:-headless}" = window ]; then
        # The nested Hyprland is a WINDOW on the user's own desktop (the
        # hands-on test): its window output is the only one.
        mons='hl.monitor({ output = "WAYLAND-1", mode = "preferred", position = "0x0", scale = 1 })'
        creates=""; outputs=1
    fi
    if [ "$outputs" -ge 2 ]; then
        mons="$mons"$'\n''hl.monitor({ output = "LOCK-2", mode = "3440x1440@60", position = "2880x0", scale = 1 })'
        # ONE command, one output after the other: two hl.exec_cmd are two processes with no order between them,
        # and whichever hyprctl reached the compositor first got monitor id 0 (measured 2026-10-15: LOCK-2 first in
        # 3 starts of 12). `&&` waits for the first create's reply, so LOCK-1 is always id 0 and LOCK-2 id 1.
        creates='    hl.exec_cmd("hyprctl output create headless LOCK-1 && hyprctl output create headless LOCK-2")'
    fi
    local auto=""
    [ -n "${AUTOSTART:-}" ] && auto="    hl.exec_cmd(\"${AUTOSTART//\"/\\\"}\")"
    MONS="$mons" CREATES="$creates" ANIM="${ANIMATIONS:-false}" XRAY="${XRAY_STATIC:-false}" AUTO="$auto" python3 - "$ROOT/tools/dev/lock_env/hyprland.lua.in" "$B/hyprland.lua" <<'PY' || die "config"
import os, sys
src = open(sys.argv[1]).read()
src = src.replace("@MONITORS@", os.environ["MONS"]).replace("@CREATE_OUTPUTS@", os.environ["CREATES"])
src = src.replace("@ANIMATIONS@", os.environ["ANIM"]).replace("@XRAY@", os.environ["XRAY"])
src = src.replace("@AUTOSTART@", os.environ["AUTO"])
open(sys.argv[2], "w").write(src)
PY

    local i host_display=wl-host
    if [ "${HOST:-headless}" = window ]; then
        # HOST=window: the user's own compositor hosts the nested Hyprland as a
        # window (xdg_wm_base v6). Only for the hands-on test -- a lock inside
        # it locks the nested session, never the user's.
        host_display="${REAL_WAYLAND:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-1}}"
        [ -S "$host_display" ] || { cmd_down; die "no Wayland socket at $host_display"; }
    else
        # shellcheck disable=SC2046
        env -i $(base_env) $(mutter_argv) --headless --no-x11 --wayland-display=wl-host \
            --virtual-monitor 640x480@60 > "$B/mutter.log" 2>&1 < /dev/null &
        echo $! > "$B/mutter.pid"
        for i in $(seq 1 80); do [ -S "$B/rt/wl-host" ] && break; sleep 0.1; done
        [ -S "$B/rt/wl-host" ] || { cmd_down; die "mutter did not start (see $B/mutter.log)"; }
    fi

    local lockargs=()
    [ -n "${LOCKED_CMD:-}" ] && lockargs=(--locked-cmd "$LOCKED_CMD")
    # shellcheck disable=SC2046
    env -i $(base_env) WAYLAND_DISPLAY="$host_display" HYPRLAND_NO_SD_VARS=1 \
        LIBSEAT_BACKEND=seatd SEATD_SOCK="$B/no-seatd.sock" \
        Hyprland -c "$B/hyprland.lua" "${lockargs[@]}" > "$B/hypr.out" 2>&1 < /dev/null &
    echo $! > "$B/hypr.pid"

    local want=1; [ "$outputs" -ge 2 ] && want=2
    local prefix="LOCK-"; [ "${HOST:-headless}" = window ] && prefix="WAYLAND-"
    for i in $(seq 1 100); do
        if [ -S "$B/rt/wayland-1" ] && [ -n "$(hypr_sig)" ]; then
            n=$(cmd_hyprctl -j monitors 2>/dev/null | python3 -c 'import json,sys
try: print(sum(1 for m in json.load(sys.stdin) if m["name"].startswith(sys.argv[1])))
except Exception: print(0)' "$prefix" 2>/dev/null)
            [ "${n:-0}" -ge "$want" ] && break
        fi
        sleep 0.1
    done
    [ "${n:-0}" -ge "$want" ] || { echo "lock_env: Hyprland outputs did not come up" >&2; tail -5 "$B/hypr.out" >&2; cmd_down; exit 1; }
    # A pointer that stays plugged in (same reason as the keyboard below),
    # driven through a FIFO: `tools/dev/lock_env.sh point "abs X Y W H" click`.
    # Built from tools/dev/lock_env/vpointer.c with wayland-scanner, once, into a
    # shared cache that is rebuilt when the source changes.
    local vp; vp=$(build_vpointer) || { cmd_down; die "vpointer build failed"; }
    mkfifo "$B/vpointer.fifo"
    # shellcheck disable=SC2046
    env -i $(client_env) "$vp" <> "$B/vpointer.fifo" > "$B/vpointer.log" 2>&1 &
    echo $! > "$B/vpointer.pid"
    # A keyboard that stays plugged in. With no physical keyboard in the seat,
    # every wtype that exits removes the LAST keyboard: the seat loses its
    # keyboard capability, the client drops its wl_keyboard, and Hyprland
    # never re-enters the lock surface on the next one -- measured: after the
    # first wtype, no key reached the lock again. This idle wtype holds one
    # keyboard for the environment's life, as a real laptop's does.
    # shellcheck disable=SC2046
    env -i $(client_env) wtype -s 2147483647 > /dev/null 2>&1 < /dev/null &
    echo $! > "$B/kbd.pid"
    touch "$B/up"
    echo "LOCK_ENV UP $NAME dir=$B sig=$(hypr_sig) outputs=$want"
}

build_vpointer() {
    local out=/tmp/lrlk-build src="$ROOT/tools/dev/lock_env/vpointer.c" xml="$ROOT/tools/dev/lock_env/wlr-virtual-pointer-unstable-v1.xml"
    mkdir -p "$out"
    if [ ! -x "$out/vpointer" ] || [ "$src" -nt "$out/vpointer" ]; then
        wayland-scanner client-header "$xml" "$out/wlr-virtual-pointer-unstable-v1-client-protocol.h" \
          && wayland-scanner private-code "$xml" "$out/wlr-virtual-pointer-protocol.c" \
          && gcc -O2 -Wall -o "$out/vpointer" "$src" "$out/wlr-virtual-pointer-protocol.c" -I"$out" \
                 $(pkg-config --cflags --libs wayland-client) >&2 || return 1
    fi
    echo "$out/vpointer"
}

cmd_down() {
    local pids p left
    pids=$(env_pids)
    [ -n "$pids" ] && kill $pids 2>/dev/null
    for p in $(cat "$B/bus.pid" 2>/dev/null); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "dbus-daemon.*$(basename "$BUSCONF")" && kill "$p" 2>/dev/null
    done
    for _ in $(seq 1 30); do left=$(env_pids); [ -z "$left" ] && break; sleep 0.1; done
    [ -n "$left" ] && kill -9 $left 2>/dev/null
    if [ -f "$B/userenv.before" ]; then
        systemctl --user show-environment > "$B/userenv.after" 2>/dev/null
        if cmp -s "$B/userenv.before" "$B/userenv.after"; then
            echo "LOCK_ENV USERENV unchanged"
        else
            echo "LOCK_ENV USERENV CHANGED:"; diff "$B/userenv.before" "$B/userenv.after" | sed 's/^/    /'
        fi
    fi
    [ -n "${KEEP:-}" ] || rm -rf "$B"
    echo "LOCK_ENV DOWN $NAME"
}

cmd_run() {
    [ -e "$B/up" ] || die "$NAME is not up"
    # shellcheck disable=SC2046
    exec env -i $(client_env) "$@"
}

cmd_hyprctl() {
    # shellcheck disable=SC2046
    env -i $(base_env) HYPRLAND_INSTANCE_SIGNATURE="$(hypr_sig)" hyprctl "$@"
}

case "${1:-}" in
    up) cmd_up ;;
    down) cmd_down ;;
    run) shift; cmd_run "$@" ;;
    hyprctl) shift; cmd_hyprctl "$@" ;;
    shot) shift; f="$1"; shift
          # shellcheck disable=SC2046
          env -i $(client_env) timeout 10 grim ${1:+-o "$1"} "$f" ;;
    type) shift
          # shellcheck disable=SC2046
          env -i $(client_env) wtype -- "$*" ;;
    point) shift; [ -p "$B/vpointer.fifo" ] || die "$NAME has no pointer"
           printf '%s\n' "$@" > "$B/vpointer.fifo" ;;
    key) shift; args=(); for k in "$@"; do args+=(-k "$k"); done
         # shellcheck disable=SC2046
         env -i $(client_env) wtype "${args[@]}" ;;
    status) [ -e "$B/up" ] && echo "LOCK_ENV $NAME up: $B" || echo "LOCK_ENV $NAME down"
            env_pids | while read -r p; do echo "  $p $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-100)"; done ;;
    dir) echo "$B" ;;
    *) sed -n '2,14p' "$0"; exit 2 ;;
esac
