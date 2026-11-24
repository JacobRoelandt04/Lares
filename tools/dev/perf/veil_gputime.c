// veil_gputime.c -- an LD_PRELOAD that times every frame of a GL client on the GPU: a GL_TIMESTAMP before the frame's first
// clear or draw and one after its last, read back a few frames later so nothing waits. Qt's GL backend issues a frame's
// command stream in one burst, then (Wayland) waits for the compositor's frame callback INSIDE its swap, before
// eglSwapBuffers: a query that ends at the swap counts that wait as GPU time (every frame of a 60 Hz lock read ~16.4 ms, its
// draws done in under 1: measured with VEIL_GPUTIME_DEBUG), and one opened at the swap counts the idle before the next.
// Qt's own `GPU frame time` (QSG_RHI_PROFILE) reads nothing here: the offscreen platform's context reports GL 2.0 and NVIDIA's
// Wayland context is GLES 3.2, and Qt asks for timestamps on neither (tools/dev/perf/veil_perf.sh, measured 2026-11-22).
//
//   cc -O2 -shared -fPIC -o veil_gputime.so tools/dev/perf/veil_gputime.c -ldl
//   LD_PRELOAD=$PWD/veil_gputime.so VEIL_GPUTIME_OUT=/path/frames.tsv quickshell ...   ("%p" in the path: the pid)
//
// Each line of the output: `<wall ms of the swap that ended the frame, CLOCK_REALTIME> <GPU ms of the frame>`, with
// VEIL_GPUTIME_DEBUG=1 also the call that opened it (c/a/e glClear / glDrawArrays / glDrawElements linked, C/A/E through
// getProcAddress), ms from the swap before to it, ms from it to its last draw, ms from that to the swap. Desktop GL
// (glXSwapBuffers: the offscreen platform) and GLES with EXT_disjoint_timer_query (eglSwapBuffers: Wayland) alike; ONE
// context is followed (the first that swaps; a window's render thread), any other is ignored. A disjoint report (the GPU's
// clock changed under a query) drops that frame. The span is the GPU's wall time from the frame's first command to its last,
// so other contexts that pre-empt it (the compositor) land in it too: read medians.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef unsigned int GLuint;
typedef unsigned int GLenum;
typedef int GLint;
typedef int GLsizei;
typedef uint64_t GLuint64;
typedef void (*fn_gen)(GLsizei, GLuint *);
typedef void (*fn_counter)(GLuint, GLenum);
typedef void (*fn_getuiv)(GLuint, GLenum, GLuint *);
typedef void (*fn_getu64)(GLuint, GLenum, GLuint64 *);
typedef void (*fn_getiv)(GLenum, GLint *);
typedef void *(*fn_proc)(const char *);

#define GL_TIMESTAMP 0x8E28
#define GL_QUERY_RESULT 0x8866
#define GL_QUERY_RESULT_AVAILABLE 0x8867
#define GL_GPU_DISJOINT 0x8FBB
#define RING 8

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int state = 0;            // 0 = not set up, 1 = running, -1 = gave up
static void *ctx = NULL;         // the context followed
static void *(*cur_ctx)(void) = NULL;
static FILE *out = NULL;
static fn_gen gen;
static fn_counter counter;
static fn_getuiv getuiv;
static fn_getu64 getu64;
static fn_getiv getiv;
static int es = 0;
static int debug = 0;
static GLuint qs[RING], qe[RING];        // a frame's first and last timestamp
static double wall[RING], prevSwap[RING], began[RING], lastDraw[RING];
static char via[RING];
static int pending[RING];
static int head = 0;                     // the slot of the frame being recorded
static int active = 0;                   // its first timestamp is out
static double lastSwap = 0;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int setup(fn_proc proc, int isEs) {
    const char *path = getenv("VEIL_GPUTIME_OUT");
    if (!path || !*path)
        return -1;
    es = isEs;
    debug = getenv("VEIL_GPUTIME_DEBUG") != NULL;
    gen = (fn_gen)proc(es ? "glGenQueriesEXT" : "glGenQueries");
    counter = (fn_counter)proc(es ? "glQueryCounterEXT" : "glQueryCounter");
    getuiv = (fn_getuiv)proc(es ? "glGetQueryObjectuivEXT" : "glGetQueryObjectuiv");
    getu64 = (fn_getu64)proc(es ? "glGetQueryObjectui64vEXT" : "glGetQueryObjectui64v");
    getiv = (fn_getiv)proc("glGetIntegerv");
    if (!gen || !counter || !getuiv || !getu64 || !getiv) {
        fprintf(stderr, "veil_gputime: no timer queries in this context (es=%d)\n", es);
        return -1;
    }
    // "%p" in the path is the process id: a supervisor that starts more than one GL client (a relaunch) keeps each
    char buf[4096];
    const char *pp = strstr(path, "%p");
    if (pp && (size_t)(pp - path) < sizeof buf - 32) {
        snprintf(buf, sizeof buf, "%.*s%d%s", (int)(pp - path), path, (int)getpid(), pp + 2);
        path = buf;
    }
    out = fopen(path, "w");
    if (!out)
        return -1;
    gen(RING, qs);
    gen(RING, qe);
    memset(pending, 0, sizeof pending);
    fprintf(stderr, "veil_gputime: following a %s context\n", es ? "GLES" : "GL");
    return 1;
}

static void collect(int force) {
    for (int k = 1; k <= RING; k++) {
        int i = (head + k) % RING;
        if (!pending[i] || i == head)
            continue;
        GLuint a = 0, b = 0;
        getuiv(qs[i], GL_QUERY_RESULT_AVAILABLE, &a);
        getuiv(qe[i], GL_QUERY_RESULT_AVAILABLE, &b);
        if ((!a || !b) && !force)
            continue;
        GLuint64 t0 = 0, t1 = 0;
        getu64(qs[i], GL_QUERY_RESULT, &t0);
        getu64(qe[i], GL_QUERY_RESULT, &t1);
        pending[i] = 0;
        GLint disjoint = 0;
        if (es)
            getiv(GL_GPU_DISJOINT, &disjoint);
        if (disjoint || t1 < t0)
            continue;
        if (debug)
            fprintf(out, "%.3f %.4f %c %.3f %.3f %.3f\n", wall[i], (t1 - t0) / 1e6, via[i], began[i] - prevSwap[i], lastDraw[i] - began[i],
                    wall[i] - lastDraw[i]);
        else
            fprintf(out, "%.3f %.4f\n", wall[i], (t1 - t0) / 1e6);
    }
    fflush(out);
}

// Called with the swapping context current: the frame is complete.
static void on_swap(void *cur, fn_proc proc, int isEs) {
    pthread_mutex_lock(&lock);
    if (state == 0) {
        state = setup(proc, isEs);
        ctx = cur;
    }
    if (state == 1 && cur == ctx && active) {
        wall[head] = now_ms();
        prevSwap[head] = lastSwap;
        lastSwap = wall[head];
        pending[head] = 1;
        head = (head + 1) % RING;
        active = 0;
        if (pending[head])  // the ring is full: wait for the oldest
            collect(1);
        collect(0);
    }
    pthread_mutex_unlock(&lock);
}

// Before a clear or draw: the frame's first one stamps its start. After it: the frame's end so far (re-issued; the last
// one before the swap is the one read).
static void before_draw(char which) {
    if (state != 1 || active || !cur_ctx || cur_ctx() != ctx)
        return;
    pthread_mutex_lock(&lock);
    if (state == 1 && !active) {
        counter(qs[head], GL_TIMESTAMP);
        began[head] = now_ms();
        via[head] = which;
        active = 1;
    }
    pthread_mutex_unlock(&lock);
}
static void after_draw(void) {
    if (state != 1 || !active || !cur_ctx || cur_ctx() != ctx)
        return;
    counter(qe[head], GL_TIMESTAMP);
    if (debug)
        lastDraw[head] = now_ms();
}

typedef void (*fn_clear)(unsigned int);
typedef void (*fn_drawarrays)(GLenum, GLint, GLsizei);
typedef void (*fn_drawelements)(GLenum, GLsizei, GLenum, const void *);
static fn_clear real_clear = NULL, gp_clear = NULL;
static fn_drawarrays real_da = NULL, gp_da = NULL;
static fn_drawelements real_de = NULL, gp_de = NULL;
// linked directly ...
void glClear(unsigned int mask) {
    if (!real_clear) real_clear = (fn_clear)dlsym(RTLD_NEXT, "glClear");
    before_draw('c');
    real_clear(mask);
    after_draw();
}
void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    if (!real_da) real_da = (fn_drawarrays)dlsym(RTLD_NEXT, "glDrawArrays");
    before_draw('a');
    real_da(mode, first, count);
    after_draw();
}
void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *idx) {
    if (!real_de) real_de = (fn_drawelements)dlsym(RTLD_NEXT, "glDrawElements");
    before_draw('e');
    real_de(mode, count, type, idx);
    after_draw();
}
// ... or resolved through getProcAddress
static void w_clear(unsigned int mask) { before_draw('C'); gp_clear(mask); after_draw(); }
static void w_da(GLenum mode, GLint first, GLsizei count) { before_draw('A'); gp_da(mode, first, count); after_draw(); }
static void w_de(GLenum mode, GLsizei count, GLenum type, const void *idx) { before_draw('E'); gp_de(mode, count, type, idx); after_draw(); }
static void *wrap_proc(const char *name, void *p) {
    if (!p || !name)
        return p;
    if (strcmp(name, "glClear") == 0) { gp_clear = (fn_clear)p; return (void *)w_clear; }
    if (strcmp(name, "glDrawArrays") == 0) { gp_da = (fn_drawarrays)p; return (void *)w_da; }
    if (strcmp(name, "glDrawElements") == 0) { gp_de = (fn_drawelements)p; return (void *)w_de; }
    return p;
}

// ---- GLX (the offscreen platform) --------------------------------------------------------------
typedef void (*fn_glxswap)(void *, unsigned long);
typedef void *(*fn_glxcur)(void);
void glXSwapBuffers(void *dpy, unsigned long drawable) {
    static fn_glxswap real = NULL;
    static fn_glxcur cur = NULL;
    static fn_proc proc = NULL;
    if (!real) {
        real = (fn_glxswap)dlsym(RTLD_NEXT, "glXSwapBuffers");
        cur = (fn_glxcur)dlsym(RTLD_NEXT, "glXGetCurrentContext");
        proc = (fn_proc)dlsym(RTLD_NEXT, "glXGetProcAddressARB");
        if (!cur_ctx) cur_ctx = cur;
    }
    if (cur && proc)
        on_swap(cur(), proc, 0);
    real(dpy, drawable);
}

// ---- EGL (Wayland) -------------------------------------------------------------------------------
typedef unsigned int (*fn_eglswap)(void *, void *);
typedef void *(*fn_eglcur)(void);
static fn_eglswap real_eglswap = NULL;
static fn_eglcur egl_cur = NULL;
static fn_proc egl_proc = NULL;
static void egl_init(void) {
    if (!real_eglswap) {
        real_eglswap = (fn_eglswap)dlsym(RTLD_NEXT, "eglSwapBuffers");
        egl_cur = (fn_eglcur)dlsym(RTLD_NEXT, "eglGetCurrentContext");
        egl_proc = (fn_proc)dlsym(RTLD_NEXT, "eglGetProcAddress");
        cur_ctx = egl_cur;
    }
}
unsigned int eglSwapBuffers(void *dpy, void *surface) {
    egl_init();
    if (egl_cur && egl_proc)
        on_swap(egl_cur(), egl_proc, 1);
    return real_eglswap(dpy, surface);
}
typedef unsigned int (*fn_eglswapdmg)(void *, void *, int *, int);
static fn_eglswapdmg real_dmg = NULL;
static unsigned int swap_damage(void *dpy, void *surface, int *rects, int n) {
    egl_init();
    if (egl_cur && egl_proc)
        on_swap(egl_cur(), egl_proc, 1);
    return real_dmg(dpy, surface, rects, n);
}
void *eglGetProcAddress(const char *name) {
    egl_init();
    void *p = egl_proc ? egl_proc(name) : NULL;
    if (p && name && (strcmp(name, "eglSwapBuffersWithDamageKHR") == 0 || strcmp(name, "eglSwapBuffersWithDamageEXT") == 0)) {
        real_dmg = (fn_eglswapdmg)p;
        return (void *)swap_damage;
    }
    if (name && strcmp(name, "eglSwapBuffers") == 0)
        return (void *)eglSwapBuffers;
    return wrap_proc(name, p);
}
