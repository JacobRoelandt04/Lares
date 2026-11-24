"""What happened, for whoever reads it after a test on the real phone: one JSON line per event in <cache>/trace.jsonl.

Kinds: `watch` (each line the watcher printed), `call` (a one-shot: its words, its answer, how long), `exec` (a command a one-shot
ran: argv, status, the tail of its output), `ident` (what the phone said over the cable about its addresses and name), `adopt` (a
cable-only key folded into a KDE Connect one), `cast` (every event lares-cast printed, and its dpi decision), `unlock` (the steps of an unlock:
lockstate results, the branch taken; never the PIN). Never raises: a trace that cannot be written is skipped. The file is rotated at
2 MB (the previous one is trace.1.jsonl). It holds serials and addresses, so it stays in the cache and never enters the repo.
"""
import json
import os
import time

MAX_BYTES = 2 * 1024 * 1024
DEFAULT = None          # the Paths of this process (lares-bridge's main sets it), for callers that hold none
KEEP_JOB_LOGS = 30


def write(paths, kind, **fields):
    paths = paths or DEFAULT
    if paths is None:
        return
    try:
        os.makedirs(paths.cache, mode=0o700, exist_ok=True)
        f = os.path.join(paths.cache, "trace.jsonl")
        try:
            if os.path.getsize(f) > MAX_BYTES:
                os.replace(f, os.path.join(paths.cache, "trace.1.jsonl"))
        except OSError:
            pass
        rec = {"t": round(time.time(), 3), "pid": os.getpid(), "kind": kind}
        rec.update(fields)
        fd = os.open(f, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (json.dumps(rec, separators=(",", ":"), ensure_ascii=False, default=str) + "\n").encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def ran(argv, rc, t0, out=""):
    """One command a one-shot ran: argv, status, milliseconds, the tail of what it printed."""
    write(None, "exec", argv=list(argv), rc=rc, ms=int((time.time() - t0) * 1000), tail=str(out)[-600:])


def job_log(paths, job_id):
    """An open binary file for a job's whole output (None when the cache cannot be written); the oldest beyond 30 go."""
    d = os.path.join(paths.cache, "jobs")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        old = sorted(n for n in os.listdir(d) if n.endswith(".log"))
        for n in old[:max(0, len(old) - KEEP_JOB_LOGS + 1)]:
            try:
                os.unlink(os.path.join(d, n))
            except OSError:
                pass
        name = "%s-%s.log" % (time.strftime("%Y%m%d-%H%M%S"), job_id)
        return open(os.path.join(d, name), "ab", buffering=0)
    except OSError:
        return None
