#!/usr/bin/env python3
"""shell_rest_sampler.py -- per-thread CPU of a running process at 100 ms, the spikes in it, their period, the threads that make them.

    shell_rest_sampler.py <pid> <seconds> [--interval-ms 100] [--spike-pct 20] [--merge-ms 300] [--settle CAP_S] [--json FILE] [--name NAME]

READ-ONLY: it reads /proc/<pid>/task/<tid>/stat, comm and children, /proc/<pid>/stat and /proc/loadavg, nothing else, and sends the process
nothing. It is safe to point at the user's own trial shell (its pid is in $XDG_RUNTIME_DIR/lares/pid; never found by name).

WHAT IT MEASURES. The utime+stime of every thread of the process, read every INTERVAL ms on a drift-free schedule; a thread's figure for an
interval is its CPU ticks in it over the interval's wall time (100 % = one core; the kernel counts in 10 ms ticks, so at 100 ms the
figures come in steps of 10 points -- a 20-point interval is two ticks). A SPIKE of a thread is an interval at or over --spike-pct (20 by
default); neighbouring spikes closer than --merge-ms are one BURST. The PROCESS's bursts are the same over the sum of its threads.

A shell that polls does it by FORKING (hyprctl, sh, gdbus, nmcli, python3 ...), and a child's CPU is not any thread's of the shell. So the
CPU of the process's CHILDREN is a series of its own, "(children reaped)": the delta of cutime+cstime in /proc/<pid>/stat, which moves when
a child is waited for (it holds the child's whole CPU, and its own children's, in 10 ms ticks), and the children alive at each sample are
listed from /proc/<pid>/task/*/children and named once (comm, and the start of the command line) -- a poller that forks shows as a train of
"(children reaped)" bursts with the name of what it ran. Children that live under one interval can be missed BY NAME (their CPU is not
missed); a repeated name is counted with its period.

--settle CAP_S: a process just started is busy (shader compiles, first reads, prewarm): wait until it has burned <= 3 % of a core for
5 seconds running (at most CAP_S seconds), say what the start cost, and only then sample. For a shell that has been up for hours leave it 0.

WHAT IT PRINTS (the verdict is the last line: `REST_SAMPLER RESULT PASS|FAIL`, PASS = it sampled; it judges nothing about the process):
  - the machine: /proc/loadavg at the start, every 10 s and at the end (the numbers beside every reading: other work on the machine is
    the first suspect of a spike nobody can explain), the interval it kept (mean, worst);
  - AT REST: the process's mean CPU, then a table of threads (name, total CPU ms, mean %, bursts, peak %), the reaped children among them;
  - THE BURSTS of the process: when, how long, how high, which threads carried it;
  - THE PERIOD: the gaps between the bursts' starts, their histogram, the median, and how many of the gaps lie within 15 % of it -- for the
    process and for each thread with at least 3 bursts. A period that is no one number reads as "no period".
  - THE CHILDREN SEEN: every distinct program the process forked while it was watched, how often it was caught, and the period of its starts.

Threads are named by /proc comm (Qt names its own: QSGRenderThread, QQmlThread, QDBusConnectionManager ...; a thread that never set a
name carries the process's). The tid is kept beside the name: two threads of one name are told apart by it.
"""
import argparse
import json
import os
import socket
import statistics
import threading
import sys
import time

CLK = os.sysconf("SC_CLK_TCK")
KIDS = "kids"          # the pseudo-thread of the CPU of the children the process has waited for


def read_stat(path):
    """(comm, ticks) from /proc/<pid>/task/<tid>/stat, or None when the thread is gone."""
    try:
        with open(path) as f:
            s = f.read()
    except OSError:
        return None
    r = s.rfind(")")
    comm = s[s.find("(") + 1:r]
    rest = s[r + 2:].split()
    try:
        return comm, int(rest[11]) + int(rest[12])      # utime + stime (fields 14, 15)
    except (IndexError, ValueError):
        return None


def read_children_cpu(pid):
    """cutime + cstime (ticks) of the process: the CPU of the children it has waited for, from /proc/<pid>/stat; None when it is gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            s = f.read()
    except OSError:
        return None
    rest = s[s.rfind(")") + 2:].split()
    try:
        return int(rest[13]) + int(rest[14])          # cutime, cstime (fields 16, 17)
    except (IndexError, ValueError):
        return None


def read_children(task, tids):
    """The pids of the live children of any thread of the process (/proc/<pid>/task/<tid>/children)."""
    kids = set()
    for tid in tids:
        try:
            with open("%s/%s/children" % (task, tid)) as f:
                kids.update(f.read().split())
        except OSError:
            pass
    return kids


def describe_child(cpid):
    """(comm, the start of its command line) of a child, read once; ('?', '') when it has already gone."""
    try:
        with open("/proc/%s/comm" % cpid) as f:
            comm = f.read().strip()
    except OSError:
        return "?", ""
    try:
        with open("/proc/%s/cmdline" % cpid, "rb") as f:
            argv = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        argv = ""
    return comm, " ".join(argv.split())[:150]          # one line: a command line may hold newlines


def total_ticks(pid):
    """utime + stime (ticks) of the whole process, or None."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            s = f.read()
    except OSError:
        return None
    rest = s[s.rfind(")") + 2:].split()
    try:
        return int(rest[11]) + int(rest[12])
    except (IndexError, ValueError):
        return None


def loadavg():
    try:
        with open("/proc/loadavg") as f:
            return f.read().split()[:3]
    except OSError:
        return ["?", "?", "?"]


def bursts_of(series, times, thresh, merge_s):
    """series: cpu% per interval (aligned with times = the interval ENDS, seconds from the start). -> [{t, dur, peak, ms}]"""
    spikes = [(times[i], series[i]) for i in range(len(series)) if series[i] >= thresh]
    out = []
    for t, v in spikes:
        if out and t - out[-1]["end"] <= merge_s:
            b = out[-1]
            b["end"] = t
            b["peak"] = max(b["peak"], v)
            b["pct_sum"] += v
            b["n"] += 1
        else:
            out.append({"start": t, "end": t, "peak": v, "pct_sum": v, "n": 1})
    return out


def finish(b, dt):
    # the interval ends at `end`; the burst began one interval earlier
    start = max(0.0, b["start"] - dt)
    return {"t": round(start, 2), "dur_ms": int(round((b["end"] - start) * 1000)), "peak": round(b["peak"], 1),
            "cpu_ms": int(round(b["pct_sum"] * dt * 10))}


def period_of(starts):
    """-> (median gap, within15 fraction, histogram {gap rounded to .5 s: count}) of the burst starts"""
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    if not gaps:
        return None, 0.0, {}
    med = statistics.median(gaps)
    near = sum(1 for g in gaps if abs(g - med) <= 0.15 * med) / len(gaps)
    hist = {}
    for g in gaps:
        k = round(g * 2) / 2
        hist[k] = hist.get(k, 0) + 1
    return med, near, dict(sorted(hist.items()))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pid", type=int)
    ap.add_argument("seconds", type=float)
    ap.add_argument("--interval-ms", type=float, default=100.0)
    ap.add_argument("--spike-pct", type=float, default=20.0)
    ap.add_argument("--merge-ms", type=float, default=300.0)
    ap.add_argument("--settle", type=float, default=0.0)
    ap.add_argument("--json", default="")
    ap.add_argument("--name", default="")
    ap.add_argument("--hypr-events", action="store_true", help="also listen (read only) on Hyprland's event socket and name the events around every burst")
    ap.add_argument("--max-bursts", type=int, default=40, help="bursts listed (all of them are in --json); 0 = every one")
    a = ap.parse_args()
    pid, dt = a.pid, a.interval_ms / 1000.0
    task = "/proc/%d/task" % pid
    if not os.path.isdir(task):
        print("REST_SAMPLER RESULT FAIL (no process %d)" % pid)
        return 1
    try:
        with open("/proc/%d/comm" % pid) as f:
            pcomm = f.read().strip()
    except OSError:
        pcomm = "?"
    label = a.name or pcomm
    print("REST_SAMPLER %s pid %d (%s), %d threads, %.0f s at %.0f ms, spike >= %.0f %% of a core, burst merge %.0f ms, load %s"
          % (label, pid, pcomm, len(os.listdir(task)), a.seconds, a.interval_ms, a.spike_pct, a.merge_ms, " ".join(loadavg())))
    settle_note = ""
    if a.settle > 0:
        base = total_ticks(pid)
        start = time.monotonic()
        quiet = 0
        last = base
        while time.monotonic() - start < a.settle:
            time.sleep(1.0)
            cur_t = total_ticks(pid)
            if cur_t is None:
                print("REST_SAMPLER RESULT FAIL (the process %d ended while settling)" % pid)
                return 1
            quiet = quiet + 1 if cur_t - last <= 3 else 0
            last = cur_t
            if quiet >= 5:
                break
        waited = time.monotonic() - start
        burned = (last - (base or 0)) * 1000 // CLK
        if quiet >= 5:
            settle_note = "settled after %.0f s (the start burned %d ms of CPU)" % (waited, burned)
        else:
            settle_note = "DID NOT SETTLE in %.0f s (%d ms of CPU burned meanwhile; it is sampled anyway)" % (waited, burned)
        print("REST_SAMPLER " + settle_note + "; load " + " ".join(loadavg()))
    hypr_ev = []                                  # (seconds since t0, "name>>data")
    if a.hypr_events:
        sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "hypr", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket2.sock")

        def tap():
            try:
                c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                c.connect(sock)
                c.settimeout(1.0)
                buf = b""
                while time.monotonic() - t0 < a.seconds + 1:
                    try:
                        chunk = c.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        hypr_ev.append((time.monotonic() - t0, line.decode("utf-8", "replace")[:90]))
            except OSError as e:
                hypr_ev.append((0.0, "TAP FAILED %s" % e))
        t0 = time.monotonic()
        threading.Thread(target=tap, daemon=True).start()
    times, samples, names = [], [], {}
    kids_seen, kid_info, kid_starts = set(), {}, {}      # pids seen once; pid -> (comm, argv); (comm, argv) -> [times]
    loads = [(0.0, loadavg())]
    t0 = time.monotonic()
    next_at = t0
    next_load = t0 + 10.0
    prev = None
    while True:
        now = time.monotonic()
        if now - t0 >= a.seconds:
            break
        cur = {}
        try:
            tids = os.listdir(task)
        except OSError:
            print("REST_SAMPLER RESULT FAIL (the process %d ended after %.1f s)" % (pid, now - t0))
            return 1
        for tid in tids:
            r = read_stat("%s/%s/stat" % (task, tid))
            if r:
                cur[tid] = r[1]
                if tid not in names or names[tid] == pcomm:
                    names[tid] = r[0]          # a thread names itself a moment after it starts
        kc = read_children_cpu(pid)
        cur[KIDS] = kc if kc is not None else (prev[1].get(KIDS, 0) if prev else 0)
        stamp = time.monotonic()
        for cp in read_children(task, tids) - kids_seen:
            kids_seen.add(cp)
            comm, argv = describe_child(cp)
            kid_starts.setdefault((comm, argv), []).append(stamp - t0)
        if prev is not None:
            times.append(stamp - t0)
            samples.append((stamp - prev[0], {t: c - prev[1].get(t, c) for t, c in cur.items()}))
        prev = (stamp, cur)
        if stamp >= next_load:
            loads.append((stamp - t0, loadavg()))
            next_load += 10.0
        next_at += dt
        wait = next_at - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        else:
            next_at = time.monotonic()          # fell behind: do not try to catch up with a burst of reads
    loads.append((time.monotonic() - t0, loadavg()))
    n = len(samples)
    if n < max(10, int(0.8 * a.seconds / dt)):
        print("REST_SAMPLER RESULT FAIL (only %d samples in %.0f s: the machine was too busy to sample)" % (n, a.seconds))
        return 1
    real = [s[0] for s in samples]
    # per-thread series, in cpu% of one core
    names[KIDS] = "(children reaped)"
    tids = sorted({t for _, d in samples for t in d})
    series = {t: [100.0 * d.get(t, 0) / CLK / w for w, d in samples] for t in tids}
    own = [t for t in tids if t != KIDS]
    total = [sum(series[t][i] for t in tids) for i in range(n)]            # the process AND its reaped children
    own_total = [sum(series[t][i] for t in own) for i in range(n)]
    merge_s = a.merge_ms / 1000.0
    rep = {"pid": pid, "name": label, "seconds": a.seconds, "samples": n, "loads": loads, "threads": [], "bursts": []}

    print("REST_SAMPLER interval kept: mean %.1f ms, worst %.1f ms; load average at 0 s / every 10 s / the end:" % (1000 * statistics.mean(real), 1000 * max(real)))
    for t, l in loads:
        print("    t=%5.1f s  uptime-load %s" % (t, " ".join(l)))
    wall = sum(real)
    print("REST_SAMPLER AT REST: the process used %.3f cores on average (%.0f ms of CPU in %.1f s); median interval %.1f %%, 95th %.1f %%, worst %.1f %%"
          % (sum(own_total) * dt / 100.0 / (wall or 1), sum(own_total) * dt * 10, wall, statistics.median(own_total),
             sorted(own_total)[int(0.95 * (n - 1))], max(own_total)))
    print("REST_SAMPLER             its reaped children used %.0f ms of CPU in the same time (%d distinct programs seen alive)"
          % (sum(series[KIDS]) * dt * 10 if KIDS in series else 0, len(kid_starts)))
    rows = []
    trow = {}
    for t in tids:
        ms = sum(series[t]) * dt * 10
        if ms < 20:
            continue
        b = bursts_of(series[t], times, a.spike_pct, merge_s)
        rows.append((ms, t, b))
    rows.sort(reverse=True)
    print("REST_SAMPLER THREADS (CPU ms over the run, mean %%, bursts of >= %.0f %%, peak %%):" % a.spike_pct)
    for ms, t, b in rows:
        pk = max(series[t])
        print("    %-26s tid %-8s %7d ms  %5.2f %%  %3d bursts  peak %5.1f %%" % (names.get(t, "?"), t if t != KIDS else "-", ms, ms / 10.0 / (wall or 1), len(b), pk))
        trow[t] = {"tid": t, "name": names.get(t, "?"), "cpu_ms": int(ms), "bursts": len(b), "peak": round(pk, 1), "period_s": None}
        rep["threads"].append(trow[t])
    quiet = len(tids) - len(rows)
    if quiet:
        print("    (%d more threads under 20 ms of CPU in the whole run)" % quiet)

    pb = bursts_of(total, times, a.spike_pct, merge_s)
    print("REST_SAMPLER THE PROCESS'S BURSTS (>= %.0f %% of a core summed over its threads and its reaped children): %d in %.0f s" % (a.spike_pct, len(pb), wall))
    shown = pb if a.max_bursts == 0 else pb[:a.max_bursts]
    for b in shown:
        fb = finish(b, dt)
        lo, hi = int(max(0, (fb["t"]) / dt)), int(min(n, (b["end"] / dt) + 1))
        carry = {}
        for t in tids:
            ms = sum(series[t][lo:hi]) * dt * 10
            if ms >= 10:
                carry[names.get(t, "?") + ("/" + t if t != KIDS else "")] = int(ms)
        top = sorted(carry.items(), key=lambda kv: -kv[1])[:4]
        print("    t=%6.1f s  %4d ms  peak %5.1f %%  %5d ms CPU   %s" % (fb["t"], fb["dur_ms"], fb["peak"], fb["cpu_ms"], ", ".join("%s %d ms" % kv for kv in top)))
        near = [e[1] for e in hypr_ev if fb["t"] - 0.6 <= e[0] <= fb["t"] + fb["dur_ms"] / 1000.0]
        if near:
            print("        hyprland events: %s" % "; ".join(sorted(set(x.split(">>")[0] for x in near))))
        rep["bursts"].append(dict(fb, threads=dict(top), hypr=near[:12]))
    if len(shown) < len(pb):
        print("    ... %d more" % (len(pb) - len(shown)))

    def show_period(label, starts):
        med, near, hist = period_of(starts)
        if med is None:
            print("    %-30s %d burst(s): no period to speak of" % (label, len(starts)))
            return None
        verdict = "a PERIOD of %.2f s (%.0f %% of the gaps within 15 %%)" % (med, 100 * near) if near >= 0.6 and len(starts) >= 4 else "no steady period (median gap %.2f s, %.0f %% within 15 %%)" % (med, 100 * near)
        print("    %-30s %3d bursts: %s; gap histogram %s" % (label, len(starts), verdict, ", ".join("%.1fs x%d" % kv for kv in list(hist.items())[:8])))
        return med if near >= 0.6 and len(starts) >= 4 else None

    print("REST_SAMPLER THE PERIOD (gaps between the starts of bursts):")
    pstarts = [finish(b, dt)["t"] for b in pb]
    rep["period_s"] = show_period("the process", pstarts)
    for ms, t, b in rows:
        if len(b) >= 3:
            trow[t]["period_s"] = show_period("%s%s" % (names.get(t, "?"), "/" + t if t != KIDS else ""), [finish(x, dt)["t"] for x in b])
    print("REST_SAMPLER THE CHILDREN SEEN (programs the process forked while it was watched; short-lived ones are caught by chance):")
    kid_rows = []
    for (comm, argv), ts in sorted(kid_starts.items(), key=lambda kv: -len(kv[1])):
        med, near, hist = period_of(ts)
        kid_rows.append({"comm": comm, "argv": argv, "seen": len(ts), "period_s": med if (near >= 0.6 and len(ts) >= 4) else None, "times": [round(x, 1) for x in ts]})
        print("    %-14s %-150s caught %3d times%s" % (comm, argv, len(ts), "; every %.1f s (%.0f %% of the gaps within 15 %%)" % (med, 100 * near) if med is not None and len(ts) >= 4 and near >= 0.6 else ""))
    if not kid_rows:
        print("    (none alive at a sample)")
    rep["children_seen"] = kid_rows
    if a.hypr_events:
        rep["hypr_events"] = [(round(t, 2), e) for t, e in hypr_ev]
        names_n = {}
        for _, e in hypr_ev:
            names_n[e.split(">>")[0]] = names_n.get(e.split(">>")[0], 0) + 1
        print("REST_SAMPLER HYPRLAND EVENTS in the run (the desktop's own activity, not the shell's): %s" % (", ".join("%s x%d" % kv for kv in sorted(names_n.items(), key=lambda kv: -kv[1])) or "none"))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rep, f, indent=1)
    print("REST_SAMPLER RESULT PASS (%d samples in %.0f s; %d process bursts; %s)"
          % (n, wall, len(pb), ("period %.2f s" % rep["period_s"]) if rep["period_s"] else "no steady period"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
