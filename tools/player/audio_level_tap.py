#!/usr/bin/env python3
"""
audio_level_tap.py — reads raw signed-16-bit-LE mono PCM from stdin,
emits "<rms> <peak>\\n" lines to stdout at ~30 Hz.

Driven by the player's PlayerLevelTap.qml: a PipeWire recorder (pw-cat /
parec) is piped into stdin, this script computes per-window RMS + peak
(both normalised 0..1), and the player smooths and draws them.

Cheap on purpose: pure stdlib, no numpy. ~8 kHz mono is enough resolution
for a level bar; higher rates just waste cycles.
"""
import sys
import struct
import math
import time

# Tunables — kept conservative so the python loop stays well under 1% CPU
# even when many taps run concurrently.
CHUNK_BYTES   = 1024     # 512 samples at s16 mono = 64 ms at 8 kHz
EMIT_INTERVAL = 0.033    # ~30 Hz output cadence


def main():
    last_emit = 0.0
    pending_rms_sq = 0.0
    pending_count = 0
    pending_peak = 0
    stdin = sys.stdin.buffer

    while True:
        data = stdin.read(CHUNK_BYTES)
        if not data:
            break
        n = len(data) // 2
        if n == 0:
            continue
        samples = struct.unpack(f"<{n}h", data[: n * 2])

        sq = 0
        peak = 0
        for s in samples:
            sq += s * s
            a = -s if s < 0 else s
            if a > peak:
                peak = a

        pending_rms_sq += sq
        pending_count += n
        if peak > pending_peak:
            pending_peak = peak

        now = time.monotonic()
        if now - last_emit >= EMIT_INTERVAL and pending_count > 0:
            rms = math.sqrt(pending_rms_sq / pending_count) / 32768.0
            peak_n = pending_peak / 32768.0
            sys.stdout.write(f"{rms:.4f} {peak_n:.4f}\n")
            sys.stdout.flush()
            pending_rms_sq = 0.0
            pending_count = 0
            pending_peak = 0
            last_emit = now


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
