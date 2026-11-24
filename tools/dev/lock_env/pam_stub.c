// A scripted PAM module for the lockscreen's tests. The lock's two PAM
// services (password, face) are pointed at a PRIVATE pam.d whose stacks use
// this module instead of pam_unix / pam_howdy, so no probe ever needs the
// user's password or camera, and none touches the real faillock tally.
//
//   auth required /path/pam_lrlk_stub.so script=/path/to/file
//
// The script is read at every pam_authenticate, one command per line:
//   sleep MS              wait (the lock's abort() SIGKILLs the PAM child
//                         mid-sleep: that is the "loser killed" case)
//   msg info|error TEXT   a PAM_TEXT_INFO / PAM_ERROR_MSG, as howdy and
//                         pam_faillock send them
//   prompt TEXT           a PAM_PROMPT_ECHO_OFF; the answer is kept
//   prompt-async TEXT     the same prompt, sent from a second thread that nothing
//                         waits for: pam_howdy's `workaround = native` -- the stack
//                         prompts for the password at ~0 ms while the scan runs on,
//                         and a later `return` / `hang` decides. The answer, if any
//                         ever came, is dropped (and never satisfies `expect`)
//   async-mark PATH       create PATH if a prompt-async (later in the script) is
//                         ever ANSWERED: a probe's proof that nobody answered it
//   expect VALUE          the last answer must equal VALUE, else the result
//                         is PAM_AUTH_ERR after the fail delay (pam_unix's)
//   faildelay MS          pam_fail_delay for a failing result
//   touch PATH            create PATH (a probe reads it: "the module ran")
//   spawn PATH            fork/exec PATH and wait for it, as pam_howdy does with
//                         compare.py: the lock's abort() kills THIS process and
//                         leaves PATH running unless something reaped it first
//   hang                  never return (the lock's stall watchdog case)
//   return NAME           success | auth_err | authinfo_unavail | ignore |
//                         system_err | cred_insufficient | maxtries
// Lines starting with # are ignored. No return line means success.
// pam_exec cannot stand in for howdy: it only sends TEXT_INFO and only
// returns SUCCESS or SYSTEM_ERR.
#define PAM_SM_AUTH
#include <security/pam_modules.h>
#include <security/pam_ext.h>
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <pthread.h>

struct async_prompt { pam_handle_t *pamh; char text[512]; char mark[512]; };

static void *async_prompt_main(void *arg) {
    struct async_prompt *p = arg;
    char *ans = NULL;
    pam_prompt(p->pamh, PAM_PROMPT_ECHO_OFF, &ans, "%s", p->text);
    if (ans) {
        if (p->mark[0]) { int fd = open(p->mark, O_CREAT | O_WRONLY, 0600); if (fd >= 0) close(fd); }
        memset(ans, 0, strlen(ans)); free(ans);
    }
    free(p);
    return NULL;
}

static int code_of(const char *name) {
    if (!strcmp(name, "success")) return PAM_SUCCESS;
    if (!strcmp(name, "auth_err")) return PAM_AUTH_ERR;
    if (!strcmp(name, "authinfo_unavail")) return PAM_AUTHINFO_UNAVAIL;
    if (!strcmp(name, "ignore")) return PAM_IGNORE;
    if (!strcmp(name, "system_err")) return PAM_SYSTEM_ERR;
    if (!strcmp(name, "cred_insufficient")) return PAM_CRED_INSUFFICIENT;
    if (!strcmp(name, "maxtries")) return PAM_MAXTRIES;
    return PAM_SYSTEM_ERR;
}

static void sleep_ms(long ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) != 0) {}
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    const char *script = NULL;
    for (int i = 0; i < argc; i++)
        if (!strncmp(argv[i], "script=", 7)) script = argv[i] + 7;
    if (!script) return PAM_SYSTEM_ERR;
    FILE *f = fopen(script, "r");
    if (!f) return PAM_SYSTEM_ERR;

    char line[1024];
    char *answer = NULL;
    char asyncmark[512] = "";
    int failed = 0, result = PAM_SUCCESS;
    long faildelay = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        char *arg = strchr(line, ' ');
        if (arg) *arg++ = 0; else arg = line + strlen(line);
        if (!strcmp(line, "sleep")) sleep_ms(atol(arg));
        else if (!strcmp(line, "msg")) {
            char *text = strchr(arg, ' ');
            if (text) *text++ = 0; else text = "";
            pam_prompt(pamh, !strcmp(arg, "error") ? PAM_ERROR_MSG : PAM_TEXT_INFO, NULL, "%s", text);
        } else if (!strcmp(line, "prompt")) {
            free(answer); answer = NULL;
            if (pam_prompt(pamh, PAM_PROMPT_ECHO_OFF, &answer, "%s", arg) != PAM_SUCCESS) {
                fclose(f); return PAM_CONV_ERR;
            }
        } else if (!strcmp(line, "prompt-async")) {
            struct async_prompt *p = calloc(1, sizeof *p);
            pthread_t th;
            if (!p) { fclose(f); return PAM_BUF_ERR; }
            p->pamh = pamh;
            snprintf(p->text, sizeof p->text, "%s", arg);
            snprintf(p->mark, sizeof p->mark, "%s", asyncmark);
            if (pthread_create(&th, NULL, async_prompt_main, p) == 0) pthread_detach(th);
            else free(p);
        } else if (!strcmp(line, "async-mark")) {
            snprintf(asyncmark, sizeof asyncmark, "%s", arg);
        } else if (!strcmp(line, "expect")) {
            if (!answer || strcmp(answer, arg)) failed = 1;
        } else if (!strcmp(line, "faildelay")) faildelay = atol(arg);
        else if (!strcmp(line, "touch")) {
            int fd = open(arg, O_CREAT | O_WRONLY, 0600);
            if (fd >= 0) close(fd);
        } else if (!strcmp(line, "spawn")) {
            pid_t c = fork();
            if (c == 0) { execl(arg, arg, (char *)NULL); _exit(127); }
            if (c > 0) { int st; while (waitpid(c, &st, 0) < 0) {} }
        } else if (!strcmp(line, "hang")) { for (;;) pause(); }
        else if (!strcmp(line, "return")) result = code_of(arg);
    }
    fclose(f);
    if (answer) { memset(answer, 0, strlen(answer)); free(answer); }
    if (failed) {
        if (faildelay > 0) pam_fail_delay(pamh, (unsigned int)(faildelay * 1000));
        return PAM_AUTH_ERR;
    }
    if (result != PAM_SUCCESS && faildelay > 0) pam_fail_delay(pamh, (unsigned int)(faildelay * 1000));
    return result;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
