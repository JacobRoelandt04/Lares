#!/usr/bin/env python3
"""Films one output with grim as fast as it goes, for tools/dev/sleep_lockenv_film.sh: WORKERS grims 30 ms apart, each frame kept as a
960 x 540 PNG named by the WALL-clock millisecond it was taken at (the stubs' logs are on the same clock), until SIGINT / SIGTERM.
(wf-recorder records on damage only, and its session ended on its own in this env: it stopped on its own in this env.)
usage (inside the env: tools/dev/lock_env.sh run python3 ...): sleep_film_sample.py OUTPUT OUTDIR [WORKERS=3]"""
import io
import os
import signal
import subprocess
import sys
import threading
import time

from PIL import Image

stop = False


def _stop(*_):
    global stop
    stop = True


signal.signal(signal.SIGINT, _stop)
signal.signal(signal.SIGTERM, _stop)
out, outdir = sys.argv[1], sys.argv[2]
workers = int(sys.argv[3]) if len(sys.argv) > 3 else 3
os.makedirs(outdir, exist_ok=True)


def worker(k):
    time.sleep(k * 0.03)
    while not stop:
        t = int(time.time() * 1000)
        r = subprocess.run(["grim", "-o", out, "-t", "ppm", "-"], capture_output=True)
        if r.returncode != 0 or not r.stdout:
            time.sleep(0.05)
            continue
        Image.open(io.BytesIO(r.stdout)).convert("RGB").resize((960, 540), Image.BILINEAR).save("%s/%d.png" % (outdir, t))


ths = [threading.Thread(target=worker, args=(k,), daemon=True) for k in range(workers)]
for th in ths:
    th.start()
while not stop:
    time.sleep(0.05)
for th in ths:
    th.join(timeout=2)
