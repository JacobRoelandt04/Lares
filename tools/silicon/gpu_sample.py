#!/usr/bin/env python3
"""gpu_sample.py <pid> -- one JSON line: what the GPU has done for a process, now.

    t           wall seconds (monotonic)
    render_ns   the process's DRM render-engine busy time, summed over its DRM clients
                (drm-engine-render in /proc/<pid>/fdinfo; one entry per drm-client-id,
                however many fds name it)
    engines     every engine the process used: {name: ns}
    clients     how many distinct DRM clients the process holds
    rc6_ms      the iGPU's rc6 (sleep) residency, ms: the WHOLE GPU's busy share is
                1 - d(rc6)/d(wall), shared with the desktop (the fallback when fdinfo
                reads 0 on a kernel; CLAUDE.md says it may here -- the runner checks that
                it moves before it trusts it)
    freq_mhz    the iGPU's clock now as the firmware's SLPC has it set (rps_cur_freq_mhz;
                800 .. 2350 MHz on this machine -- rps_act_freq_mhz reads 0 whenever the
                sample lands in an rc6 gap): the same work costs more milliseconds at a low
                clock, and a lightly loaded GPU runs low -- the numbers are the operating
                point of a quiet desktop, not a boosted one

It reads only /proc and /sys files: it never opens a DRM device, so it cannot wake the
dGPU. Used by calibrate_overhead.sh beside it.
"""
import glob
import json
import os
import re
import sys
import time


def fdinfo(pid):
    clients = {}
    for f in glob.glob(f"/proc/{pid}/fdinfo/*"):
        try:
            t = open(f).read()
        except OSError:
            continue
        m = re.search(r"drm-client-id:\s*(\d+)", t)
        if not m:
            continue
        eng = {k: int(v) for k, v in re.findall(r"drm-engine-([a-z\-]+):\s*(\d+) ns", t)}
        clients[m.group(1)] = eng
    return clients


def gt_file(name):
    for d in sorted(glob.glob("/sys/class/drm/card*/device/driver")):
        if os.path.basename(os.path.realpath(d)) != "i915":
            continue
        card = d.split("/")[4]
        try:
            return int(open(f"/sys/class/drm/{card}/gt/gt0/{name}").read())
        except OSError:
            continue
    return -1


def rc6_ms():
    return gt_file("rc6_residency_ms")


def main():
    pid = sys.argv[1]
    clients = fdinfo(pid)
    engines = {}
    for eng in clients.values():
        for k, v in eng.items():
            engines[k] = engines.get(k, 0) + v
    print(json.dumps({
        "t": time.monotonic(),
        "render_ns": engines.get("render", -1) if clients else -1,
        "engines": engines,
        "clients": len(clients),
        "rc6_ms": rc6_ms(),
        "freq_mhz": gt_file("rps_cur_freq_mhz"),
    }))


if __name__ == "__main__":
    main()
