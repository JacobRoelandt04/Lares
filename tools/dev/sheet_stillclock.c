// sheet_stillclock.c -- LD_PRELOAD for the sheet check's reference sheet (tools/dev/sheet_render.py): one wall clock and one
// stream of entropy for every run, so that a state renders the same picture today and next week.
//
//   The wall clock stands still at SHEET_NOW (seconds since the epoch): every date, relative time, market state and mock
//   record of the shell derives from it. CLOCK_MONOTONIC is left alone: Qt's timers and event loop need it to run.
//   getentropy / getrandom hand out a fixed stream: QRandomGenerator seeds from them, so Math.random() and the particle
//   systems draw the same numbers in the same order. Nothing here is secret: only a test's process ever loads this.
//   With SHEET_EXECLOG=<file> every program started is appended there: a state's list of what it ran on this machine, the
//   proof that the sheet asks no real daemon (`execve` and friends are the only way out of a process, and this is inherited).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static long long now_s(void)
{
    static long long v = -1;
    if (v < 0) {
        const char *e = getenv("SHEET_NOW");
        v = e ? atoll(e) : 1793199600LL;
    }
    return v;
}

int clock_gettime(clockid_t id, struct timespec *ts)
{
    static int (*real)(clockid_t, struct timespec *);
    if (!real)
        real = dlsym(RTLD_NEXT, "clock_gettime");
    if (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE || id == CLOCK_TAI) {
        ts->tv_sec = now_s();
        ts->tv_nsec = 0;
        return 0;
    }
    return real(id, ts);
}

int gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    tv->tv_sec = now_s();
    tv->tv_usec = 0;
    return 0;
}

time_t time(time_t *t)
{
    time_t v = now_s();
    if (t)
        *t = v;
    return v;
}

// xorshift64, one byte per step
static unsigned long long stream = 0x9E3779B97F4A7C15ULL;
static void fill(void *p, size_t n)
{
    unsigned char *c = p;
    for (size_t i = 0; i < n; i++) {
        stream ^= stream << 13;
        stream ^= stream >> 7;
        stream ^= stream << 17;
        c[i] = (unsigned char)(stream >> 32);
    }
}

int getentropy(void *b, size_t n)
{
    fill(b, n);
    return 0;
}

ssize_t getrandom(void *b, size_t n, unsigned int flags)
{
    (void)flags;
    fill(b, n);
    return (ssize_t)n;
}

// ---- what a state runs ------------------------------------------------------------------------------------------
// In the child of a fork, before the exec: only calls that are safe there. The real functions are found at load, not here.
static int (*real_execve)(const char *, char *const[], char *const[]);
static int (*real_execvpe)(const char *, char *const[], char *const[]);
static int (*real_posix_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
static int (*real_posix_spawnp)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
extern char **environ;

__attribute__((constructor)) static void find_real(void)
{
    real_execve = dlsym(RTLD_NEXT, "execve");
    real_execvpe = dlsym(RTLD_NEXT, "execvpe");
    real_posix_spawn = dlsym(RTLD_NEXT, "posix_spawn");
    real_posix_spawnp = dlsym(RTLD_NEXT, "posix_spawnp");
}

static void note(const char *path, char *const argv[])
{
    const char *f = getenv("SHEET_EXECLOG");
    if (!f)
        return;
    int fd = open(f, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    char line[1024];
    size_t n = 0;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    for (size_t k = strlen(base); k > 0 && n < sizeof line - 2; k--)
        line[n++] = *base++;
    for (int i = 1; argv && argv[i] && n < sizeof line - 2; i++) {
        line[n++] = ' ';
        for (const char *c = argv[i]; *c && n < sizeof line - 2; c++)
            line[n++] = *c == '\n' ? ' ' : *c;
    }
    line[n++] = '\n';
    if (write(fd, line, n) < 0) { /* a log line is not worth failing an exec for */ }
    close(fd);
}

int execve(const char *p, char *const a[], char *const e[])
{
    note(p, a);
    return real_execve(p, a, e);
}

int execv(const char *p, char *const a[])
{
    note(p, a);
    return real_execve(p, a, environ);
}

int execvp(const char *p, char *const a[])
{
    note(p, a);
    return real_execvpe(p, a, environ);
}

int execvpe(const char *p, char *const a[], char *const e[])
{
    note(p, a);
    return real_execvpe(p, a, e);
}

int posix_spawn(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at, char *const a[], char *const e[])
{
    note(p, a);
    return real_posix_spawn(pid, p, fa, at, a, e);
}

int posix_spawnp(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at, char *const a[], char *const e[])
{
    note(p, a);
    return real_posix_spawnp(pid, p, fa, at, a, e);
}
