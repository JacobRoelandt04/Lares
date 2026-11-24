"""The batch loop: progress file, lock, resume, events, exit codes. What an item does is pipeline.py's.

    run(tab, resume, payload, *, make_ctx, process_item, emit, log, n_cap) -> exit code

The files (CONTRACT.md "Paths"): `batch/<tab>.progress.json` and `batch/<tab>.lock`.

    progress = {"v": 1, "tab", "batch", "plan": [...], "n", "seed", "settled": [1, 2, ...],
                "done": [ids], "counts": {"ok", "skipped", "failed"}, "running": true, "pid", "startedAt"}

`settled` are the plan positions (1-based) that reached a terminal event (done, skip or fail); `done` are the ids of
the entries written. The file is rewritten atomically after EVERY item, before that item's event goes out, so a
kill -9 loses at most the item in flight (and its image files, which nobody points at). `running` stays true
until the loop ends: the service reads a `running` file with no live process behind it as "relaunch with --resume",
and only the flock decides whether one is still alive (a second batch of the same tab finds it held: exit 2).

`--resume` takes the plan, `n` and `settled` from the file (stdin then carries only `recent` and `n`) and works on
the positions that are not settled; `start.todo` says how many. The `end` event carries the CUMULATIVE ok / skipped /
failed of the whole batch (a resumed run adds to what the first process did) and `jev: {tokens, calls}` of THIS
process.

Signals. SIGTERM ends the loop cleanly (the card is given back, `end` goes out) and decides whether the batch may be
resumed: sent by the shell to cancel (its parent is still there) the file says `running: false`; sent by the kernel
because the parent died (`setpriv --pdeathsig`: a shell reload) it stays `running: true`, so the next shell resumes.

Exit codes: 0 (even with skips and failures), 2 (a batch of this tab is already running, or a bad request), 3 (blocked:
the card was needed and refused, and nothing could be produced), 4 (the network is down and nothing could be produced).
"""
import os
import signal
import time

from . import atomic, env, http, ndjson, paths

OFFLINE_ABORT = 2          # consecutive items that met a dead network before the batch gives up


class Terminated(BaseException):
    pass


def _now_ms():
    return int(time.time() * 1000)


def _batch_id(tab):
    return "%s-%s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), tab)


def read_progress(tab):
    p = atomic.read_json(paths.progress_path(tab))
    return p if isinstance(p, dict) else None


def run(tab, resume, payload, *, make_ctx, process_item, emit=ndjson.emit, log=env.log, n_cap=None):
    t0 = time.monotonic()
    lock = atomic.Lock(paths.lock_path(tab), blocking=False)
    try:
        lock.acquire()
    except atomic.Busy:
        log("another %s batch is already running (%s)" % (tab, paths.lock_path(tab)))
        return 2
    try:
        prog = read_progress(tab)
        if resume:
            if not prog or not prog.get("plan") or not prog.get("running"):
                emit({"ev": "start", "batch": (prog or {}).get("batch") or _batch_id(tab), "tab": tab,
                      "n": len((prog or {}).get("plan") or []), "todo": 0, "resumed": True})
                emit({"ev": "end", "ok": 0, "skipped": 0, "failed": 0, "ms": 0})
                return 0
            plan = prog["plan"]
            seed = prog.get("seed")
            settled = set(int(x) for x in prog.get("settled", []))
            done_ids = list(prog.get("done", []))
            counts = dict({"ok": 0, "skipped": 0, "failed": 0}, **(prog.get("counts") or {}))
            batch_id = prog.get("batch") or _batch_id(tab)
            started = prog.get("startedAt") or _now_ms()
        else:
            plan = payload.get("plan")
            if not isinstance(plan, list):
                log("batch: stdin carries no plan")
                return 2
            if n_cap and n_cap > 0:
                plan = plan[:n_cap]                          # --n caps the plan; a shorter plan is what it is
            seed = None
            settled, done_ids, counts = set(), [], {"ok": 0, "skipped": 0, "failed": 0}
            batch_id, started = _batch_id(tab), _now_ms()
        n = len(plan)
        state = {"v": 1, "tab": tab, "batch": batch_id, "plan": plan, "n": n, "settled": sorted(settled),
                 "done": done_ids, "counts": counts, "running": True, "pid": os.getpid(), "startedAt": started}
        ctx = make_ctx(batch_id, payload, seed)
        state["seed"] = ctx.seed
        ppid0 = os.getppid()
        gone = {"pipe": False}

        def out(ev):
            """emit, unless the reader is gone (a reload closed the pipe): the batch goes on and stays resumable."""
            if gone["pipe"]:
                return
            try:
                emit(ev)
            except BrokenPipeError:
                gone["pipe"] = True

        def on_term(signum, frame):
            raise Terminated()

        old = signal.signal(signal.SIGTERM, on_term)
        cancelled = reload_kill = abort_offline = False
        offline_run = 0
        try:
            atomic.write_json(paths.progress_path(tab), state)
            out({"ev": "start", "batch": batch_id, "tab": tab, "n": n, "todo": n - len(settled),
                 "resumed": bool(resume)})
            for i in range(1, n + 1):
                if i in settled:
                    continue
                item = plan[i - 1]
                try:
                    res = process_item(ctx, i, n, item)
                    offline_run = 0
                except http.Offline as e:
                    offline_run += 1
                    log("network down at item %d: %s" % (i, e))
                    res = {"status": "fail", "reason": "offline", "family": (item or {}).get("family", "")}
                except Terminated:
                    raise
                except Exception as e:                       # noqa: BLE001 -- one bad item must not end the batch
                    import traceback
                    log("item %d failed:\n%s" % (i, "".join(traceback.format_exception(type(e), e, e.__traceback__))))
                    res = {"status": "fail", "reason": "%s: %s" % (type(e).__name__, str(e)[:160]),
                           "family": (item or {}).get("family", "")}
                counts["ok" if res["status"] == "done" else "skipped" if res["status"] == "skip" else "failed"] += 1
                if res["status"] == "done":
                    done_ids.append(res["id"])
                settled.add(i)
                state["settled"] = sorted(settled)
                atomic.write_json(paths.progress_path(tab), state)
                if res["status"] == "done":
                    out({"ev": "done", "i": i, "n": n, "id": res["id"], "row": res["row"],
                         "generated": res.get("generated", False), "ms": int((time.monotonic() - t0) * 1000)})
                elif res["status"] == "skip":
                    out({"ev": "skip", "i": i, "reason": res["reason"], "family": res.get("family", "")})
                else:
                    out({"ev": "fail", "i": i, "reason": res["reason"], "family": res.get("family", "")})
                if offline_run >= OFFLINE_ABORT and counts["ok"] == 0:
                    abort_offline = True
                    break
        except Terminated:
            if os.getppid() == ppid0:
                cancelled = True                              # the shell is alive: this was a cancel
            else:
                reload_kill = True                            # the parent died (pdeathsig): resume next time
        finally:
            signal.signal(signal.SIGTERM, old)
            try:
                ctx.close()
            except BaseException as e:                       # noqa: BLE001
                log("giving the card back failed: %s" % e)
        state["running"] = reload_kill
        atomic.write_json(paths.progress_path(tab), state)
        if reload_kill:
            return 0
        out({"ev": "end", "ok": counts["ok"], "skipped": counts["skipped"], "failed": counts["failed"],
             "ms": int((time.monotonic() - t0) * 1000), "jev": ctx.jev_usage()})
        if counts["ok"] == 0 and ctx.gpu.blocked:
            return 3
        if counts["ok"] == 0 and abort_offline:
            return 4
        return 0
    finally:
        lock.release()
