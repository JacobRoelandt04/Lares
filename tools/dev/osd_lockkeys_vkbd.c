// osd_lockkeys_vkbd.c -- a keyboard that presses REAL keycodes in a nested Hyprland (tools/dev/lock_env.sh), for
// tools/dev/osd_lockkeys_probe.sh.
//
// wtype cannot press Caps Lock as a keyboard does: it gives each symbol the next free keycode of its own keymap (the
// first is 9), and Hyprland's bind lookup reads the keycode through the seat's layout, so `wtype -k Caps_Lock` is
// Escape to a bind. This one uploads the stock us keymap (evdev rules, pc105) and sends the evdev codes a laptop's
// keyboard sends (KEY_CAPSLOCK 58, KEY_NUMLOCK 69), so the compositor's bind lookup sees what it sees for the real key.
// The lock modifiers follow the key as a hardware keyboard's do: Hyprland takes a virtual keyboard's modifiers from the
// client, so after a lock key's press the client's own xkb state is told the key and its modifiers are sent.
//
//   osd_lockkeys_vkbd CMD...      run in the env: tools/dev/lock_env.sh run osd_lockkeys_vkbd tap 58 sleep 400 tap 69
//     tap CODE        press + release (80 ms apart)
//     down CODE / up CODE
//     sleep MS
// Built by the probe with wayland-scanner from tools/stt/ime/protocols/virtual-keyboard-unstable-v1.xml.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *vkm;
static struct zwp_virtual_keyboard_v1 *vk;
static struct xkb_state *state;
static struct wl_display *dpy;

static void global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t ver) {
    (void)d; (void)ver;
    if (!strcmp(iface, wl_seat_interface.name))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
        vkm = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener listener = { global, global_remove };

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void send_key(int code, int down) {
    zwp_virtual_keyboard_v1_key(vk, now_ms(), (uint32_t)code, down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    xkb_state_update_key(state, (xkb_keycode_t)(code + 8), down ? XKB_KEY_DOWN : XKB_KEY_UP);
    zwp_virtual_keyboard_v1_modifiers(vk, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
                                      xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
                                      xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
                                      xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
    wl_display_roundtrip(dpy);
    struct timespec wall;
    clock_gettime(CLOCK_REALTIME, &wall);
    printf("vkbd %s %d %lld\n", down ? "down" : "up", code, (long long)wall.tv_sec * 1000 + wall.tv_nsec / 1000000);
    fflush(stdout);
}

int main(int argc, char **argv) {
    dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "vkbd: no display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &listener, NULL);
    wl_display_roundtrip(dpy);
    if (!seat || !vkm) { fprintf(stderr, "vkbd: no seat or virtual keyboard manager\n"); return 1; }

    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names us = { "evdev", "pc105", "us", "", "" };
    struct xkb_keymap *km = xkb_keymap_new_from_names(ctx, &us, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!km) { fprintf(stderr, "vkbd: no us keymap\n"); return 1; }
    state = xkb_state_new(km);
    char *text = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t sz = strlen(text) + 1;
    int fd = memfd_create("vkbd-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, text, sz) != (ssize_t)sz) { fprintf(stderr, "vkbd: keymap fd\n"); return 1; }
    vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vkm, seat);
    zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)sz);
    wl_display_roundtrip(dpy);
    usleep(150000);    // the compositor adds the device and makes it the seat's main keyboard
    printf("vkbd ready\n");
    fflush(stdout);

    for (int i = 1; i < argc; i++) {
        const char *c = argv[i];
        int v = i + 1 < argc ? atoi(argv[i + 1]) : 0;
        if (!strcmp(c, "tap") && i + 1 < argc) {
            send_key(v, 1);
            usleep(80000);
            send_key(v, 0);
            i++;
        } else if (!strcmp(c, "down") && i + 1 < argc) {
            send_key(v, 1);
            i++;
        } else if (!strcmp(c, "up") && i + 1 < argc) {
            send_key(v, 0);
            i++;
        } else if (!strcmp(c, "sleep") && i + 1 < argc) {
            usleep((useconds_t)v * 1000);
            i++;
        } else {
            fprintf(stderr, "vkbd: unknown command %s\n", c);
            return 2;
        }
    }
    usleep(300000);    // the last key's events reach the clients before the device goes
    zwp_virtual_keyboard_v1_destroy(vk);
    wl_display_roundtrip(dpy);
    free(text);
    return 0;
}
