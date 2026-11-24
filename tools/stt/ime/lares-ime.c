// lares-ime -- the dictation's input method: a zwp_input_method_v2 client (and one zwp_virtual_keyboard_v1) for one take.
//
// The shell (modules/dictation/DictationService.qml) starts it per take and ends it per take, so no app ever sees an input method
// unless the user is dictating. It never grabs the keyboard. Lines on stdin / stdout, fields TAB-separated, text escaped as \\ \n \t:
//
//   shell -> ime   preedit<TAB>text        the provisional words (shown underlined by the app), replacing the last preedit
//                  commit<TAB>text         final text at the cursor; the preedit is cleared
//                  delete<TAB>before<TAB>after   bytes around the cursor (unused by the prototype: committed text is never revised)
//                  type<TAB>text           the virtual keyboard types it (an app with no text input): committed text only
//                  quit
//   `lares-ime --type-only` binds no input method, only the virtual keyboard: Hyprland ignores the keys of a virtual keyboard whose
//   client holds the input method, so the typing route runs a second lares-ime this way.
//   ime -> shell   ready<TAB>2             bound (2: this protocol, with the rebind; the shell asks a rebuild of an older binary);
//                                          `activate` follows at once when a focused field takes text (Hyprland 0.57.1 enters a
//                                          new input method into the focused surface's text inputs)
//                  rebound<TAB>ms          no `activate` came REBIND_MS after `ready`: the input method was destroyed and bound
//                                          again once (THE REBIND, below); ms is what the two round trips cost
//                  activate / deactivate   a text field gained / lost focus (applied at the compositor's `done`)
//                  content<TAB>hint<TAB>purpose        zwp_text_input_v3 content type (purpose 8 password, 10 pin, 13 terminal)
//                  surrounding<TAB>text<TAB>cursor<TAB>anchor
//                  done<TAB>serial
//                  unavailable             another input method holds the seat: the take goes elsewhere
//                  typed<TAB>n             the virtual keyboard sent n characters
//                  error<TAB>message
//
// A commit over 4000 bytes (the protocol's cap) goes out as several commit cycles, cut at UTF-8 boundaries.
// THE REBIND (round 5). Hyprland 0.57.1 sends `activate` only from a text input's ENABLE, and an enable made while no input method
// exists is dropped (CTextInput::onEnabled). A new input method enters the focused client's text inputs (onNewIME -> enter), but
// enter() returns at once for a text input that is already on that surface -- one entered with no input method around: made while
// its window had the focus (an app that makes its text input when a window is first focused), or left behind by a take whose focus
// moved (onKeyboardFocus ignores a surface equal to its stale `m_lastKbFocus`, so the text input of the window left is never left).
// Such a field was enabled long ago, gets no new enter, never enables again: no `activate`, the take goes to the clipboard -- "the
// first take in a window is not live, the second is" (the destroy of the first take's input method leaves it, so the next bind
// enters it afresh). So when no `activate` has come REBIND_MS after `ready`, the input method is destroyed (Hyprland's destroy
// listener leaves the focused text input: the app disables) and bound again (onNewIME enters it: the app enables, `activate`
// comes), ONCE. With no field focused it costs one more bind and changes nothing.
// THE VIRTUAL KEYBOARD types with keycodes that carry NO symbol in the seat's keymap nor in the stock us one (kb_keymap), so a bind
// resolved through the user's layout can never fire from it (wtype's first key is keycode 9, read as Escape: CLAUDE.md). One
// device per run; the keymap is uploaded per run of text (type_text).
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

#define CAP 4000
#define REBIND_MS 200
// what `ready` says: the shell (DictationService imeVersion) asks for a rebuild of a binary older than its source
#define LARES_IME_VERSION 2

static struct wl_display *dpy;
static struct wl_seat *seat;
static struct zwp_input_method_manager_v2 *imm;
static struct zwp_virtual_keyboard_manager_v1 *vkm;
static struct zwp_input_method_v2 *im;
static struct zwp_virtual_keyboard_v1 *vk;
static struct wl_keyboard *kbd;

static int active, pend_active, serial, unavailable, ever_active;
static uint32_t pend_hint, pend_purpose;
static char *pend_text;
static uint32_t pend_cursor, pend_anchor;
static int pend_have_text, pend_have_content;

// the seat keymap's free keycodes, and what our keymap has given them
static int free_codes[256], n_free;
static uint32_t given[256];
static int n_given;
static int vk_ready;

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

static void put_escaped(const char *s) {
    for (; *s; s++) {
        if (*s == '\\') fputs("\\\\", stdout);
        else if (*s == '\n') fputs("\\n", stdout);
        else if (*s == '\t') fputs("\\t", stdout);
        else putchar(*s);
    }
}

static void unescape(char *s) {
    char *w = s;
    for (char *r = s; *r; r++) {
        if (*r == '\\' && r[1]) {
            r++;
            *w++ = *r == 'n' ? '\n' : *r == 't' ? '\t' : *r;
        } else {
            *w++ = *r;
        }
    }
    *w = 0;
}

// ---- input method events ----------------------------------------------------------------------------------------------------
static void im_activate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; pend_active = 1; }
static void im_deactivate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; pend_active = 0; }
static void im_surrounding(void *d, struct zwp_input_method_v2 *m, const char *text, uint32_t cursor, uint32_t anchor) {
    (void)d; (void)m;
    free(pend_text);
    pend_text = strdup(text ? text : "");
    pend_cursor = cursor;
    pend_anchor = anchor;
    pend_have_text = 1;
}
static void im_cause(void *d, struct zwp_input_method_v2 *m, uint32_t cause) { (void)d; (void)m; (void)cause; }
static void im_content(void *d, struct zwp_input_method_v2 *m, uint32_t hint, uint32_t purpose) {
    (void)d; (void)m;
    pend_hint = hint;
    pend_purpose = purpose;
    pend_have_content = 1;
}
static void im_done(void *d, struct zwp_input_method_v2 *m) {
    (void)d; (void)m;
    serial++;
    if (pend_active != active) {
        active = pend_active;
        if (active) ever_active = 1;
        out(active ? "activate" : "deactivate");
    }
    if (pend_have_content) {
        out("content\t%u\t%u", pend_hint, pend_purpose);
        pend_have_content = 0;
    }
    if (pend_have_text) {
        fputs("surrounding\t", stdout);
        put_escaped(pend_text);
        out("\t%u\t%u", pend_cursor, pend_anchor);
        pend_have_text = 0;
    }
    out("done\t%d", serial);
}
static void im_unavailable(void *d, struct zwp_input_method_v2 *m) {
    (void)d; (void)m;
    unavailable = 1;
    out("unavailable");
}
static const struct zwp_input_method_v2_listener im_listener = {
    .activate = im_activate, .deactivate = im_deactivate, .surrounding_text = im_surrounding,
    .text_change_cause = im_cause, .content_type = im_content, .done = im_done, .unavailable = im_unavailable,
};

// ---- the seat's keymap: which keycodes carry no symbol --------------------------------------------------------------------------
static int has_syms(struct xkb_keymap *km, int kc) {
    const xkb_keysym_t *syms;
    return km && xkb_keymap_key_get_syms_by_level(km, kc, 0, 0, &syms) > 0;
}

// THE FREE KEYCODES: none of their keys carries a symbol, neither in the seat's keymap as it stands (the user's layout, unless a
// virtual keyboard typed last) nor in the stock evdev / pc105 / us one (in a us layout that is 18 of them: 97, 103, 120 ...). Binds
// are looked up through the user's layout, so a key on one of them can fire none. Below 240 only: Hyprland passes higher codes
// on, and the client types nothing for them (measured: 244 / 245 typed nothing where 9 and up did).
static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size) {
    (void)d; (void)k;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) { close(fd); return; }
    if (n_free > 0) { close(fd); return; }          // the first keymap is the seat's own; later ones are ours coming back
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return;
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *seatmap = xkb_keymap_new_from_buffer(ctx, map, strnlen(map, size), XKB_KEYMAP_FORMAT_TEXT_V1,
                                                            XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    struct xkb_rule_names us = { "evdev", "pc105", "us", "", "" };
    struct xkb_keymap *stock = xkb_keymap_new_from_names(ctx, &us, XKB_KEYMAP_COMPILE_NO_FLAGS);
    n_free = 0;
    for (int kc = 9; kc < 240 && n_free < (int)(sizeof free_codes / sizeof free_codes[0]); kc++)
        if (!has_syms(seatmap, kc) && !has_syms(stock, kc))
            free_codes[n_free++] = kc;
    if (seatmap) xkb_keymap_unref(seatmap);
    if (stock) xkb_keymap_unref(stock);
    xkb_context_unref(ctx);
}
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys) {
    (void)d; (void)k; (void)s; (void)sf; (void)keys;
}
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) { (void)d; (void)k; (void)s; (void)sf; }
static void kb_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st) {
    (void)d; (void)k; (void)s; (void)t; (void)key; (void)st;
}
static void kb_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) {
    (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g;
}
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl) { (void)d; (void)k; (void)r; (void)dl; }
static const struct wl_keyboard_listener kb_listener = {
    .keymap = kb_keymap, .enter = kb_enter, .leave = kb_leave, .key = kb_key, .modifiers = kb_mods, .repeat_info = kb_repeat,
};

// ---- registry ---------------------------------------------------------------------------------------------------------------------
static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d; (void)ver;
    if (!strcmp(iface, wl_seat_interface.name) && !seat)
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwp_input_method_manager_v2_interface.name))
        imm = wl_registry_bind(r, name, &zwp_input_method_manager_v2_interface, 1);
    else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
        vkm = wl_registry_bind(r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener reg_listener = { .global = reg_global, .global_remove = reg_remove };

// ---- requests -----------------------------------------------------------------------------------------------------------------
static size_t utf8_cut(const char *s, size_t len, size_t cap) {
    if (len <= cap) return len;
    size_t n = cap;
    while (n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80) n--;
    return n;
}

static void send_preedit(const char *t) {
    size_t len = utf8_cut(t, strlen(t), CAP);
    char *c = strndup(t, len);
    zwp_input_method_v2_set_preedit_string(im, c, (int32_t)len, (int32_t)len);
    zwp_input_method_v2_commit(im, serial);
    free(c);
}

static void send_commit(const char *t) {
    size_t len = strlen(t), off = 0;
    do {
        size_t n = utf8_cut(t + off, len - off, CAP);
        char *c = strndup(t + off, n);
        zwp_input_method_v2_set_preedit_string(im, "", 0, 0);
        zwp_input_method_v2_commit_string(im, c);
        zwp_input_method_v2_commit(im, serial);
        free(c);
        off += n;
    } while (off < len);
}

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int upload_keymap(void) {
    char *buf = NULL;
    size_t sz = 0;
    FILE *f = open_memstream(&buf, &sz);
    fprintf(f, "xkb_keymap {\nxkb_keycodes \"qs\" {\n minimum = 8;\n maximum = 255;\n");
    for (int i = 0; i < n_given; i++) fprintf(f, " <Q%d> = %d;\n", i, free_codes[i]);
    fprintf(f, "};\nxkb_types \"qs\" { include \"complete\" };\nxkb_compatibility \"qs\" { include \"complete\" };\n"
               "xkb_symbols \"qs\" {\n");
    for (int i = 0; i < n_given; i++) {
        char name[64];
        if (xkb_keysym_get_name(given[i], name, sizeof name) <= 0) snprintf(name, sizeof name, "0x%x", given[i]);
        fprintf(f, " key <Q%d> { [ %s ] };\n", i, name);
    }
    fprintf(f, "};\n};\n");
    fclose(f);
    int fd = memfd_create("lares-ime-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, buf, sz + 1) != (ssize_t)(sz + 1)) { free(buf); if (fd >= 0) close(fd); return -1; }
    zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)(sz + 1));
    close(fd);
    free(buf);
    vk_ready = 1;
    return 0;
}

static int code_of(xkb_keysym_t sym) {   // the keycode our keymap gives a symbol, giving it the next free one (-1: full)
    for (int i = 0; i < n_given; i++)
        if (given[i] == sym) return free_codes[i];
    if (n_given >= n_free) return -1;
    given[n_given++] = sym;
    return free_codes[n_given - 1];
}

static xkb_keysym_t sym_at(const unsigned char **pp) {   // the next character's keysym (NoSymbol: none), advancing past it
    const unsigned char *p = *pp;
    int n = *p < 0x80 ? 1 : (*p >> 5) == 6 ? 2 : (*p >> 4) == 14 ? 3 : 4;
    uint32_t cp = n == 1 ? *p : n == 2 ? *p & 0x1F : n == 3 ? *p & 0x0F : *p & 0x07;
    int i = 1;
    for (; i < n && p[i]; i++) cp = (cp << 6) | (p[i] & 0x3F);
    *pp = p + i;
    return cp == '\n' ? XKB_KEY_Return : cp == '\t' ? XKB_KEY_Tab : xkb_utf32_to_keysym(cp);
}

// THE KEYMAP GOES UP BEFORE THE KEYS: the symbols of a run of text are given keycodes, the keymap uploaded and the compositor's
// answer awaited, then the run's keys. There are only a few free keycodes (18 in a us layout), so a longer text goes in runs, each
// with the keymap of its own characters.
static void type_text(const char *t) {
    if (!vkm || !seat) { out("error\tno virtual keyboard"); return; }
    if (!vk) vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vkm, seat);
    if (n_free == 0) { out("error\tno free keycode in the seat's keymap"); return; }
    int sent = 0;
    const unsigned char *p = (const unsigned char *)t;
    while (*p) {
        // the run: as far as the free keycodes reach
        n_given = 0;
        const unsigned char *q = p, *end = p;
        while (*q) {
            const unsigned char *r = q;
            xkb_keysym_t sym = sym_at(&r);
            if (sym != XKB_KEY_NoSymbol && code_of(sym) < 0) break;
            q = r;
            end = q;
        }
        if (end == p) { out("error\tthe keymap is full"); break; }
        if (upload_keymap()) { out("error\tthe keymap did not upload"); break; }
        zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
        wl_display_roundtrip(dpy);
        usleep(20000);         // let the compositor hand the keymap to the focused client before the first key
        while (p < end) {
            xkb_keysym_t sym = sym_at(&p);
            if (sym == XKB_KEY_NoSymbol) continue;
            int kc = code_of(sym);
            zwp_virtual_keyboard_v1_key(vk, now_ms(), kc - 8, WL_KEYBOARD_KEY_STATE_PRESSED);
            wl_display_flush(dpy);
            usleep(2000);      // a 2 ms gap: Hyprland drops keys sent faster under load (research 6.3)
            zwp_virtual_keyboard_v1_key(vk, now_ms(), kc - 8, WL_KEYBOARD_KEY_STATE_RELEASED);
            wl_display_flush(dpy);
            usleep(2000);
            sent++;
        }
        wl_display_roundtrip(dpy);
    }
    out("typed\t%d", sent);
}

static void bind_im(void) {
    im = zwp_input_method_manager_v2_get_input_method(imm, seat);
    zwp_input_method_v2_add_listener(im, &im_listener, NULL);
}

// THE REBIND (top of the file): destroy, let the compositor act on it (it leaves the focused text input), bind again. The new object
// counts its own `done`s, so the serial starts over; events still in flight for the old one are dropped by libwayland.
static void rebind(void) {
    uint32_t t0 = now_ms();
    zwp_input_method_v2_destroy(im);
    im = NULL;
    wl_display_roundtrip(dpy);
    serial = 0;
    active = pend_active = 0;
    pend_have_text = pend_have_content = 0;
    bind_im();
    wl_display_roundtrip(dpy);
    out("rebound\t%u", now_ms() - t0);
}

static int handle_line(char *line) {
    char *tab = strchr(line, '\t');
    char *arg = tab ? tab + 1 : (char *)"";
    if (tab) *tab = 0;
    if (!strcmp(line, "quit")) return 1;
    if (!strcmp(line, "type")) { unescape(arg); type_text(arg); return 0; }
    if (unavailable) { out("error\tunavailable"); return 0; }
    if (!strcmp(line, "preedit")) { unescape(arg); send_preedit(arg); }
    else if (!strcmp(line, "commit")) { unescape(arg); send_commit(arg); }
    else if (!strcmp(line, "delete")) {
        char *t2 = strchr(arg, '\t');
        uint32_t before = (uint32_t)strtoul(arg, NULL, 10), after = t2 ? (uint32_t)strtoul(t2 + 1, NULL, 10) : 0;
        zwp_input_method_v2_delete_surrounding_text(im, before, after);
        zwp_input_method_v2_commit(im, serial);
    } else out("error\tunknown request %s", line);
    wl_display_flush(dpy);
    return 0;
}

int main(int argc, char **argv) {
    int type_only = argc > 1 && !strcmp(argv[1], "--type-only");
    dpy = wl_display_connect(NULL);
    if (!dpy) { out("error\tno Wayland display"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!seat || (!imm && !type_only)) { out("error\tthe compositor offers no %s", !seat ? "seat" : "zwp_input_method_manager_v2"); return 1; }
    kbd = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(kbd, &kb_listener, NULL);
    if (!type_only) {
        bind_im();
    } else {
        unavailable = 1;               // no input method: preedit / commit / delete are refused
    }
    wl_display_roundtrip(dpy);
    out("ready\t%d", LARES_IME_VERSION);
    // THE REBIND's deadline: once, only for an input method that is not refused (type-only binds none)
    int rebind_due = !type_only && REBIND_MS >= 0;
    uint32_t rebind_at = now_ms() + (REBIND_MS > 0 ? REBIND_MS : 0);

    char buf[65536];
    size_t have = 0;
    struct pollfd fds[2] = { { .fd = wl_display_get_fd(dpy), .events = POLLIN }, { .fd = 0, .events = POLLIN } };
    int quit = 0;
    while (!quit) {
        while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        int wait = -1;
        if (rebind_due) {
            int32_t left = (int32_t)(rebind_at - now_ms());
            wait = left > 0 ? left : 0;
        }
        if (poll(fds, 2, wait) < 0) {
            wl_display_cancel_read(dpy);
            if (errno == EINTR) continue;
            break;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(dpy) < 0) break;
        } else {
            wl_display_cancel_read(dpy);
        }
        if (wl_display_dispatch_pending(dpy) < 0) break;
        if (fds[0].revents & (POLLERR | POLLHUP)) break;
        if (rebind_due && (ever_active || unavailable)) rebind_due = 0;
        if (rebind_due && (int32_t)(rebind_at - now_ms()) <= 0) {
            rebind_due = 0;
            rebind();
        }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(0, buf + have, sizeof buf - 1 - have);
            if (n <= 0) break;          // the shell closed our stdin: the take is over
            have += (size_t)n;
            buf[have] = 0;
            char *start = buf, *nl;
            while (!quit && (nl = memchr(start, '\n', have - (size_t)(start - buf)))) {
                *nl = 0;
                quit = handle_line(start);
                start = nl + 1;
            }
            have -= (size_t)(start - buf);
            memmove(buf, start, have);
            if (have == sizeof buf - 1) have = 0;   // a line longer than the buffer is dropped
        }
    }
    // leaving: drop our preedit; the app keeps what was committed
    if (im && active && !unavailable) {
        zwp_input_method_v2_set_preedit_string(im, "", 0, 0);
        zwp_input_method_v2_commit(im, serial);
    }
    if (vk) zwp_virtual_keyboard_v1_destroy(vk);
    if (im) zwp_input_method_v2_destroy(im);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
