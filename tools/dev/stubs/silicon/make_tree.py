#!/usr/bin/env python3
"""Build tools/dev/fixtures/silicon/data/ -- the fake /sys + /proc tree the silicon service probe runs on.

    tools/dev/stubs/silicon/make_tree.py [<capture>] [<dest>]

The tree is THIS machine's captured knob tree (stage 0, 2026-10-02: helpers/silicon_helper/tests/
fixtures/n6506mv_618lts, 502 files, 29 links, Core Ultra 9 185H / RTX 4060 / ASUS Vivobook N6506MV,
kernel 6.18 lts) plus the volatile files the capture could not hold, so the same tree serves the
stand-in helper (tools/dev/stubs/silicon/silicon-helper) and, in test mode, stage 2's real binary:

  sys/devices/system/cpu/cpufreq/policyN/scaling_cur_freq   (22; cpu i reads 400000 + 50000 i kHz,
                                                             so the clock is the mean: 925 MHz)
  sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/renderD129/dev   the NVIDIA card's render node
  proc/stat                       22 CPUs with idle counters (the probe rewrites it to make load)
  proc/sys/kernel/random/boot_id  and proc/driver/nvidia/gpus/0000:01:00.0/information (Device Minor: 0)
  proc/modules                    nvidia is loaded (the MUX pre-check's first condition)
  proc/meminfo                    24 GB of RAM (7.3 GiB available) and a 25 GB swap partition, as this laptop reads
  usr/lib/modules/<kernel>/{pkgbase,updates/dkms/nvidia.ko.zst}   two installed kernels, each with its
                                  DKMS module (the pre-check's second: a module for EVERY installed kernel)
  state/firmware_caps.json        what the firmware's boot recorded: MSR 65/115 W, MMIO 45/115 W

Everything else is the capture, byte for byte. The probe copies the tree and works on the copy; the
original is hashed before and after and must not change. Run it again only to rebuild.
"""
import json
import os
import shutil
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
capture = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "helpers", "silicon_helper", "tests", "fixtures", "n6506mv_618lts")
dest = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "tools", "dev", "fixtures", "silicon", "data")

tree = os.path.join(dest, "tree")
if os.path.exists(dest):
    shutil.rmtree(dest)
os.makedirs(dest)
shutil.copytree(os.path.join(capture, "sys"), os.path.join(tree, "sys"), symlinks=True)


def put(path, text):
    p = os.path.join(tree, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


for i in range(22):
    put("sys/devices/system/cpu/cpufreq/policy%d/scaling_cur_freq" % i, "%d\n" % (400000 + 50000 * i))

put("sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/renderD129/dev", "226:129\n")
put("proc/sys/kernel/random/boot_id", "4d0c1e2f-5a6b-4c7d-8e9f-a0b1c2d3e4f5\n")
put("proc/modules", "nvidia 62345216 190 nvidia_modeset,nvidia_uvm, Live 0x0000000000000000 (POE)\nnvidia_modeset 1646592 5 nvidia_drm, Live 0x0000000000000000 (POE)\n")
put("proc/meminfo", "MemTotal:       24007296 kB\nMemFree:         2387144 kB\nMemAvailable:    7707952 kB\nBuffers:          261612 kB\nCached:          6228924 kB\nSwapCached:        35284 kB\nActive:         12340712 kB\nInactive:        6028992 kB\nSwapTotal:      26214396 kB\nSwapFree:       25726928 kB\nZswap:            120956 kB\nZswapped:         439292 kB\nDirty:              1236 kB\nShmem:           1856632 kB\n")
for kernel, base in (("6.18.54-1-lts", "linux-lts"), ("7.2.7-arch1-1", "linux")):
    put("usr/lib/modules/%s/pkgbase" % kernel, base + "\n")
    put("usr/lib/modules/%s/updates/dkms/nvidia.ko.zst" % kernel, "")
put("proc/driver/nvidia/gpus/0000:01:00.0/information", "Model: \t\t NVIDIA GeForce RTX 4060 Laptop GPU\nIRQ:   \t\t 184\nGPU UUID: \t GPU-00000000-0000-0000-0000-000000000000\nVideo BIOS: \t 95.07.2e.00.f1\nBus Type: \t PCIe\nDMA Size: \t 47 bits\nDevice Minor: \t 0\n")

# /proc/stat: 22 CPUs. user nice system idle iowait irq softirq steal guest guest_nice
lines = []
tot = [0] * 10
cpus = []
for i in range(22):
    f = [1000 + 10 * i, 0, 500 + 5 * i, 100000 + 100 * i, 200, 0, 50, 0, 0, 0]
    cpus.append(f)
    tot = [a + b for a, b in zip(tot, f)]
lines.append("cpu  " + " ".join(str(x) for x in tot))
for i, f in enumerate(cpus):
    lines.append("cpu%d " % i + " ".join(str(x) for x in f))
lines += ["intr 1000 0 0", "ctxt 5000", "btime 1790000000", "processes 4000", "procs_running 1", "procs_blocked 0"]
put("proc/stat", "\n".join(lines) + "\n")

os.makedirs(os.path.join(dest, "state"))
with open(os.path.join(dest, "state", "firmware_caps.json"), "w") as f:
    json.dump({"bootId": "4d0c1e2f-5a6b-4c7d-8e9f-a0b1c2d3e4f5",
               "msr": {"pl1W": 65, "pl2W": 115}, "mmio": {"pl1W": 45, "pl2W": 115}}, f)
    f.write("\n")

n = sum(len(fs) for _, _, fs in os.walk(tree))
print("tree: %d files + %d links under %s" % (n, sum(1 for r, ds, fs in os.walk(tree) for d in ds + fs if os.path.islink(os.path.join(r, d))), tree))
