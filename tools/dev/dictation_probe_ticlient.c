// dictation_probe_ticlient.c -- the dictation probe's stand-in for an app whose text field was ENABLED BEFORE the take's input
// method bound (tools/dev/dictation_probe.sh step I; built by the runner, never installed).
//
// A plain Wayland window (xdg-shell, a flat shm buffer) that makes its zwp_text_input_v3 only once its window HAS the keyboard
// focus -- as an app that makes its input context when a window is first focused does. Hyprland 0.57.1 enters a text input made
// while its client's surface has the focus at once (CTextInput's constructor), the client enables (as kitty and Chromium do on
// `enter`), and with no input method around that enable is dropped. A later input method's bind then finds the text input already
// on the surface (enter() returns early): no new enter, no new enable, no `activate` -- the user's "first take in that window is not
// live". lares-ime's rebind is what makes such a field live (tools/stt/ime/lares-ime.c, THE REBIND).
//
// stdout, one line each:  focused | unfocused | ti-made | ti-enter | ti-leave | preedit<TAB>text | commit<TAB>text | done
// stdin: `quit` (or EOF) ends it.
#define _GNU_SOURCE
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "text-input-unstable-v3-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#define W 480
#define H 120

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_seat *seat;
static struct zwp_text_input_manager_v3 *tim;
static struct zwp_text_input_v3 *ti;
static struct wl_surface *surf;
static struct wl_keyboard *kbd;
static int configured, quit;
static char *pend_pre, *pend_com;

static void line(const char *a, const char *b) {
    if (b) printf("%s\t%s\n", a, b);
    else printf("%s\n", a);
    fflush(stdout);
}

// ---- the text input: enabled on every enter, disabled on every leave (kitty's and Chromium's way) -------------------------------
static void ti_enter(void *d, struct zwp_text_input_v3 *t, struct wl_surface *s) {
    (void)d; (void)s;
    line("ti-enter", NULL);
    zwp_text_input_v3_enable(t);
    zwp_text_input_v3_set_content_type(t, ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    zwp_text_input_v3_commit(t);
}
static void ti_leave(void *d, struct zwp_text_input_v3 *t, struct wl_surface *s) {
    (void)d; (void)s;
    line("ti-leave", NULL);
    zwp_text_input_v3_disable(t);
    zwp_text_input_v3_commit(t);
}
static void ti_preedit(void *d, struct zwp_text_input_v3 *t, const char *text, int32_t b, int32_t e) {
    (void)d; (void)t; (void)b; (void)e;
    free(pend_pre);
    pend_pre = strdup(text ? text : "");
}
static void ti_commit(void *d, struct zwp_text_input_v3 *t, const char *text) {
    (void)d; (void)t;
    free(pend_com);
    pend_com = strdup(text ? text : "");
}
static void ti_delete(void *d, struct zwp_text_input_v3 *t, uint32_t b, uint32_t a) { (void)d; (void)t; (void)b; (void)a; }
static void ti_done(void *d, struct zwp_text_input_v3 *t, uint32_t serial) {
    (void)d; (void)t; (void)serial;
    if (pend_com) line("commit", pend_com);
    if (pend_pre) line("preedit", pend_pre);
    free(pend_pre);
    free(pend_com);
    pend_pre = pend_com = NULL;
    line("done", NULL);
}
static const struct zwp_text_input_v3_listener ti_listener = {
    .enter = ti_enter, .leave = ti_leave, .preedit_string = ti_preedit, .commit_string = ti_commit,
    .delete_surrounding_text = ti_delete, .done = ti_done,
};

// ---- the keyboard: the text input is made at the window's first focus -----------------------------------------------------------
static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t sz) { (void)d; (void)k; (void)f; (void)sz; close(fd); }
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys) {
    (void)d; (void)k; (void)s; (void)keys;
    if (sf != surf) return;
    line("focused", NULL);
    if (!ti && tim) {
        ti = zwp_text_input_manager_v3_get_text_input(tim, seat);
        zwp_text_input_v3_add_listener(ti, &ti_listener, NULL);
        line("ti-made", NULL);
    }
}
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) {
    (void)d; (void)k; (void)s;
    if (sf == surf) line("unfocused", NULL);
}
static void kb_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st) { (void)d; (void)k; (void)s; (void)t; (void)key; (void)st; }
static void kb_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) { (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g; }
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl) { (void)d; (void)k; (void)r; (void)dl; }
static const struct wl_keyboard_listener kb_listener = {
    .keymap = kb_keymap, .enter = kb_enter, .leave = kb_leave, .key = kb_key, .modifiers = kb_mods, .repeat_info = kb_repeat,
};

// ---- the window ----------------------------------------------------------------------------------------------------------------------
static struct wl_buffer *make_buffer(void) {
    int stride = W * 4, size = stride * H;
    int fd = memfd_create("ticlient", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) < 0) return NULL;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { close(fd); return NULL; }
    for (int i = 0; i < W * H; i++) px[i] = 0xFFE6E9F0;
    munmap(px, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, W, H, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return b;
}
static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { .ping = wm_ping };
static void xs_configure(void *d, struct xdg_surface *x, uint32_t s) {
    (void)d;
    xdg_surface_ack_configure(x, s);
    if (!configured) {
        configured = 1;
        wl_surface_attach(surf, make_buffer(), 0, 0);
        wl_surface_damage(surf, 0, 0, W, H);
    }
    wl_surface_commit(surf);
}
static const struct xdg_surface_listener xs_listener = { .configure = xs_configure };
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) { (void)d; (void)t; (void)w; (void)h; (void)st; }
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; quit = 1; }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name)) comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name) && !seat) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwp_text_input_manager_v3_interface.name)) tim = wl_registry_bind(r, name, &zwp_text_input_manager_v3_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = { .global = reg_global, .global_remove = reg_remove };

int main(void) {
    dpy = wl_display_connect(NULL);
    if (!dpy) { line("error", "no Wayland display"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!comp || !shm || !wm || !seat || !tim) { line("error", "a global is missing"); return 1; }
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    kbd = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(kbd, &kb_listener, NULL);
    surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surf);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "dictation probe field");
    xdg_toplevel_set_app_id(top, "lares-ticlient");
    wl_surface_commit(surf);
    line("ready", NULL);

    struct pollfd fds[2] = { { .fd = wl_display_get_fd(dpy), .events = POLLIN }, { .fd = 0, .events = POLLIN } };
    char buf[256];
    while (!quit) {
        while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        if (poll(fds, 2, -1) < 0) { wl_display_cancel_read(dpy); break; }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(dpy) < 0) break;
        } else {
            wl_display_cancel_read(dpy);
        }
        if (wl_display_dispatch_pending(dpy) < 0) break;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(0, buf, sizeof buf - 1);
            if (n <= 0) break;
            buf[n] = 0;
            if (strstr(buf, "quit")) break;
        }
    }
    if (ti) zwp_text_input_v3_destroy(ti);
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(xs);
    wl_surface_destroy(surf);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
