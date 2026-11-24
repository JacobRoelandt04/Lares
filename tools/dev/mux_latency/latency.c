// latency.c -- tools/dev/mux_bench.sh's latency client: how many frames after a client DECIDES a frame does it reach the glass.
//
// A plain xdg toplevel drawn with EGL + GLES2 (on whatever GPU the EGL vendor picks: NVIDIA's in dGPU-only, Mesa's in Hybrid). Every
// frame: read the clock (the instant an animation would read its time and decide what to draw), draw a colour that depends on it,
// ask wp_presentation for feedback on that commit, eglSwapBuffers. The compositor's `presented` event says when the frame was
// actually shown (scanout), on the presentation clock (CLOCK_MONOTONIC here). The decide -> presented time, in refresh periods, is
// the latency every animation of that client carries: one to two periods is a client that waits for each frame, more is a driver
// that queues frames ahead (NVIDIA's __GL_MaxFramesAllowed) or a compositor that holds a frame (a GPU fence).
//
//   latency <frames> <out.tsv>        prints one LATENCY line (JSON) and writes one row per frame: decide_ns presented_ns refresh_ns flags
//
// Build: cc -O2 -o latency latency.c xdg-shell.c presentation-time.c $(pkg-config --cflags --libs wayland-client wayland-egl egl glesv2)
// (the two protocol .c / .h pairs come from wayland-scanner; tools/dev/mux_bench.sh builds it in its out dir).
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp;
static struct xdg_wm_base *wm;
static struct wp_presentation *pres;
static clockid_t pres_clock = CLOCK_MONOTONIC;
static int configured, closed;
static int W = 400, H = 300;

typedef struct { int64_t decide, presented, refresh; uint32_t flags; int state; } Frame;  // state 0 pending, 1 presented, 2 discarded
static Frame *frames;
static int nframes;

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(pres_clock, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void fb_sync(void *d, struct wp_presentation_feedback *f, struct wl_output *o) { (void)d; (void)f; (void)o; }
static void fb_presented(void *d, struct wp_presentation_feedback *f, uint32_t hi, uint32_t lo, uint32_t nsec, uint32_t refresh,
                         uint32_t shi, uint32_t slo, uint32_t flags) {
    (void)shi; (void)slo;
    Frame *fr = d;
    fr->presented = ((int64_t)(((uint64_t)hi << 32) | lo)) * 1000000000LL + nsec;
    fr->refresh = refresh;
    fr->flags = flags;
    fr->state = 1;
    wp_presentation_feedback_destroy(f);
}
static void fb_discarded(void *d, struct wp_presentation_feedback *f) {
    ((Frame *)d)->state = 2;
    wp_presentation_feedback_destroy(f);
}
static const struct wp_presentation_feedback_listener fb_l = { fb_sync, fb_presented, fb_discarded };

static void pres_clock_id(void *d, struct wp_presentation *p, uint32_t id) { (void)d; (void)p; pres_clock = (clockid_t)id; }
static const struct wp_presentation_listener pres_l = { pres_clock_id };

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_l = { wm_ping };

static void surf_conf(void *d, struct xdg_surface *s, uint32_t serial) { (void)d; xdg_surface_ack_configure(s, serial); configured = 1; }
static const struct xdg_surface_listener surf_l = { surf_conf };

static void top_conf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
    (void)d; (void)t; (void)st;
    if (w > 0 && h > 0) { W = w; H = h; }
}
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; closed = 1; }
static void top_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) { (void)d; (void)t; (void)w; (void)h; }
static void top_caps(void *d, struct xdg_toplevel *t, struct wl_array *c) { (void)d; (void)t; (void)c; }
static const struct xdg_toplevel_listener top_l = { top_conf, top_close, top_bounds, top_caps };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name)) comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) { wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &wm_l, NULL); }
    else if (!strcmp(iface, wp_presentation_interface.name)) { pres = wl_registry_bind(r, name, &wp_presentation_interface, 1); wp_presentation_add_listener(pres, &pres_l, NULL); }
    (void)ver;
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };

// LAT_MODE: "" (eglSwapInterval 1, the driver paces), "finish" (glFinish before the swap: the buffer is done when it is committed),
// "manual" (eglSwapInterval 0 and the client waits for its own wl_surface.frame callback, then decides: the shortest honest path)
static int frame_done;
static void cb_done(void *d, struct wl_callback *cb, uint32_t t) { (void)d; (void)t; wl_callback_destroy(cb); frame_done = 1; }
static const struct wl_callback_listener cb_l = { cb_done };

static int cmp64(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) {
    nframes = argc > 1 ? atoi(argv[1]) : 600;
    const char *out = argc > 2 ? argv[2] : NULL;
    frames = calloc(nframes, sizeof(Frame));
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { printf("LATENCY {\"error\":\"no wayland display\"}\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);
    wl_display_roundtrip(dpy);
    if (!comp || !wm || !pres) { printf("LATENCY {\"error\":\"missing globals (wp_presentation %s)\"}\n", pres ? "yes" : "no"); return 1; }

    struct wl_surface *surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surf);
    xdg_surface_add_listener(xs, &surf_l, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &top_l, NULL);
    xdg_toplevel_set_title(top, "lares-bench-latency");
    xdg_toplevel_set_app_id(top, "lares-bench");
    wl_surface_commit(surf);
    while (!configured && wl_display_dispatch(dpy) >= 0) {}

    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlat = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay ed = getPlat ? getPlat(EGL_PLATFORM_WAYLAND_KHR, dpy, NULL) : eglGetDisplay((EGLNativeDisplayType)dpy);
    if (!eglInitialize(ed, NULL, NULL)) { printf("LATENCY {\"error\":\"eglInitialize\"}\n"); return 1; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint ca[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0,
                    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
    EGLConfig cfg; EGLint n = 0;
    eglChooseConfig(ed, ca, &cfg, 1, &n);
    EGLint cx[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(ed, cfg, EGL_NO_CONTEXT, cx);
    struct wl_egl_window *ew = wl_egl_window_create(surf, W, H);
    EGLSurface es = eglCreateWindowSurface(ed, cfg, (EGLNativeWindowType)ew, NULL);
    eglMakeCurrent(ed, es, es, ctx);
    const char *mode = getenv("LAT_MODE") ? getenv("LAT_MODE") : "";
    int manual = !strcmp(mode, "manual"), finish = !strcmp(mode, "finish");
    eglSwapInterval(ed, manual ? 0 : 1);
    const char *vendor = eglQueryString(ed, EGL_VENDOR);
    const char *rend = (const char *)glGetString(GL_RENDERER);

    // a few frames to map and settle, not counted
    for (int i = 0; i < 30 && !closed; i++) {
        glClearColor(0.1f, 0.1f, 0.15f, 1); glClear(GL_COLOR_BUFFER_BIT); eglSwapBuffers(ed, es);
        wl_display_dispatch_pending(dpy);
    }
    for (int i = 0; i < nframes && !closed; i++) {
        if (manual && i > 0) {   // the first frame goes at once; every later one waits for the callback the one before asked for
            while (!frame_done && wl_display_dispatch(dpy) >= 0) {}
        }
        frame_done = 0;
        frames[i].decide = now_ns();
        float t = (float)((frames[i].decide / 1000000) % 1000) / 1000.0f;
        // a little GPU work, as a small animated client has: a few full clears with scissored blocks
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0.12f, 0.14f, 0.2f, 1); glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_SCISSOR_TEST);
        glScissor((int)(t * (W - 60)), H / 2 - 30, 60, 60);
        glClearColor(0.27f, 0.5f, 0.96f, 1); glClear(GL_COLOR_BUFFER_BIT);
        if (finish) glFinish();
        struct wp_presentation_feedback *fb = wp_presentation_feedback(pres, surf);
        wp_presentation_feedback_add_listener(fb, &fb_l, &frames[i]);
        if (manual) {
            struct wl_callback *cb = wl_surface_frame(surf);
            wl_callback_add_listener(cb, &cb_l, NULL);
        }
        eglSwapBuffers(ed, es);
        wl_display_dispatch_pending(dpy);
    }
    // collect the last feedback
    for (int k = 0; k < 50; k++) { wl_display_roundtrip(dpy); int left = 0; for (int i = 0; i < nframes; i++) left += frames[i].state == 0; if (!left) break; }

    int64_t *lat = calloc(nframes, sizeof(int64_t)); int m = 0, disc = 0, zc = 0; int64_t refresh = 0;
    FILE *f = out ? fopen(out, "w") : NULL;
    for (int i = 0; i < nframes; i++) {
        if (f) fprintf(f, "%lld\t%lld\t%lld\t%u\t%d\n", (long long)frames[i].decide, (long long)frames[i].presented, (long long)frames[i].refresh, frames[i].flags, frames[i].state);
        if (frames[i].state == 1) { lat[m++] = frames[i].presented - frames[i].decide; refresh = frames[i].refresh; if (frames[i].flags & WP_PRESENTATION_FEEDBACK_KIND_ZERO_COPY) zc++; }
        else if (frames[i].state == 2) disc++;
    }
    if (f) fclose(f);
    qsort(lat, m, sizeof(int64_t), cmp64);
    double per = refresh > 0 ? refresh / 1e6 : 8.333;
    #define Q(p) (m ? lat[(int)((p) * (m - 1))] / 1e6 : -1)
    printf("LATENCY {\"mode\":\"%s\",\"egl_vendor\":\"%s\",\"renderer\":\"%s\",\"presented\":%d,\"discarded\":%d,\"zero_copy\":%d,\"refresh_ms\":%.3f,"
           "\"p50_ms\":%.2f,\"p95_ms\":%.2f,\"max_ms\":%.2f,\"p50_frames\":%.2f,\"p95_frames\":%.2f}\n",
           mode, vendor ? vendor : "?", rend ? rend : "?", m, disc, zc, per, Q(0.5), Q(0.95), Q(1.0), Q(0.5) / per, Q(0.95) / per);
    return 0;
}
