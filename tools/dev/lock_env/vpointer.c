// A virtual pointer for tools/dev/lock_env.sh: one long-lived pointer device in
// the nested Hyprland's seat, driven by commands on stdin (the env keeps it
// on a FIFO). With no physical mouse in the seat, a pointer that exists only
// while a command runs would take the seat's pointer capability away every
// time it exits -- the same trap the idle wtype keyboard avoids.
//
// Commands, one per line (coordinates in the layout's logical pixels):
//   abs X Y W H     move to (X, Y) within an extent of W x H
//   rel DX DY       move by (DX, DY), as a mouse does (what follows a pointer the compositor warped)
//   down / up       left button press / release
//   click           press + release
//   rclick          right button press + release
//   wheel DY        vertical scroll by DY (wl_fixed units, 10 = one step)
//   notch N         N notches of a mouse's wheel, down for + (15 units and one discrete step each, as a real mouse sends them)
//   finger DX DY    a touchpad's two fingers: both axes, source finger
//   lift            the fingers leave (axis_stop on both)
//   side back|fwd down|up     a side button's press / release
//   sleep MS
// Built with wayland-scanner from the protocol XML beside this file (the
// test env's `up` builds it; no pywayland needed).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *manager;

static void global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t ver) {
    (void)data;
    if (!strcmp(iface, wl_seat_interface.name))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
        manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, ver < 2 ? ver : 2);
}
static void global_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener listener = { global, global_remove };

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "vpointer: no display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &listener, NULL);
    wl_display_roundtrip(dpy);
    if (!seat || !manager) { fprintf(stderr, "vpointer: no seat or virtual pointer manager\n"); return 1; }
    struct zwlr_virtual_pointer_v1 *ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    wl_display_roundtrip(dpy);
    printf("vpointer ready\n");
    fflush(stdout);

    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        unsigned x, y, w, h;
        int dy, ms, rx, ry;
        if (sscanf(line, "abs %u %u %u %u", &x, &y, &w, &h) == 4) {
            zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), x, y, w, h);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (sscanf(line, "rel %d %d", &rx, &ry) == 2) {
            zwlr_virtual_pointer_v1_motion(ptr, now_ms(), wl_fixed_from_int(rx), wl_fixed_from_int(ry));
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (!strncmp(line, "down", 4) || !strncmp(line, "click", 5)) {
            zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(ptr);
            if (!strncmp(line, "click", 5)) {
                wl_display_flush(dpy);
                usleep(30000);
                zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
                zwlr_virtual_pointer_v1_frame(ptr);
            }
        } else if (!strncmp(line, "rclick", 6)) {
            zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_RIGHT, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(ptr);
            wl_display_flush(dpy);
            usleep(30000);
            zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_RIGHT, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (!strncmp(line, "up", 2)) {
            zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (sscanf(line, "wheel %d", &dy) == 1) {
            zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis(ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(dy));
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (sscanf(line, "notch %d", &dy) == 1) {
            for (int i = 0; i < (dy < 0 ? -dy : dy); i++) {
                int s = dy < 0 ? -1 : 1;
                zwlr_virtual_pointer_v1_axis_discrete(ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(15 * s), s);
                zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
                zwlr_virtual_pointer_v1_frame(ptr);
            }
        } else if (sscanf(line, "finger %d %d", &rx, &ry) == 2) {
            // Hyprland (0.57.2) keeps a source PER AXIS and sets the one of the axis last named: the axis first, then its source
            if (rx != 0) {
                zwlr_virtual_pointer_v1_axis(ptr, now_ms(), WL_POINTER_AXIS_HORIZONTAL_SCROLL, wl_fixed_from_int(rx));
                zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
            }
            if (ry != 0) {
                zwlr_virtual_pointer_v1_axis(ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(ry));
                zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
            }
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (!strncmp(line, "lift", 4)) {
            zwlr_virtual_pointer_v1_axis_stop(ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL);
            zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
            zwlr_virtual_pointer_v1_axis_stop(ptr, now_ms(), WL_POINTER_AXIS_HORIZONTAL_SCROLL);
            zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (!strncmp(line, "side ", 5)) {
            zwlr_virtual_pointer_v1_button(ptr, now_ms(), strstr(line, "fwd") ? BTN_EXTRA : BTN_SIDE,
                                           strstr(line, "down") ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(ptr);
        } else if (sscanf(line, "sleep %d", &ms) == 1) {
            wl_display_flush(dpy);
            usleep((useconds_t)ms * 1000);
        }
        wl_display_flush(dpy);
        wl_display_roundtrip(dpy);
    }
    zwlr_virtual_pointer_v1_destroy(ptr);
    wl_display_flush(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
