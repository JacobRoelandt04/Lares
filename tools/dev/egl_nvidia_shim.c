/* egl_nvidia_shim.c -- LD_PRELOAD that makes Mesa answer "NVIDIA Corporation" to eglQueryString(dpy, EGL_VENDOR).
 *
 * WHY. In dGPU-only mode Qt takes OpenGL ES on purpose when the EGL vendor says NVIDIA (qeglconvenience.cpp), and Qt 6.12 then links a
 * ShaderEffect with no vertex shader of its own at GLSL ES 1.00 (CLAUDE.md "Shaders and the GPU"). On the Intel desktop Qt takes desktop GL
 * and never runs those variants, so no gate sees what NVIDIA's driver is handed. With this shim Mesa runs the same ES path:
 *   cc -shared -fPIC -O2 -o egl_nvidia_shim.so tools/dev/egl_nvidia_shim.c -ldl
 *   LD_PRELOAD=$PWD/egl_nvidia_shim.so ...
 * (tools/dev/silicon_board_probe.sh builds it on demand with SHIM=1.) Everything else passes through. It lies about the vendor string and
 * nothing more: Mesa still compiles the shaders, with Mesa's own tolerance (no NVIDIA front end), so a pass here proves the ES 1.00 variant
 * is valid and DRAWS on Mesa's ES driver, not that NVIDIA's compiler accepts it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

#define EGL_VENDOR 0x3053

typedef const char *(*query_fn)(void *dpy, int name);

const char *eglQueryString(void *dpy, int name)
{
    static query_fn real;
    if (!real)
        real = (query_fn)dlsym(RTLD_NEXT, "eglQueryString");
    if (name == EGL_VENDOR)
        return "NVIDIA Corporation";
    return real ? real(dpy, name) : NULL;
}
