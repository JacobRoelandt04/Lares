#!/usr/bin/env python3
"""screenshot: grim (full) or grim -g "$(slurp)" (region), scaled, ONE JSON line.

    python3 -I shot.py -- full|region

Prints {"w","h","b64","thumbB64"}: the PNG scaled to at most 1568 px on the
long edge (the vision path's size), and a JPEG thumbnail of at most 12 KB of
base64 (the attachment loader's rule) for the transcript's block. The region
mode runs slurp with NO placeholder anywhere near it -- the whole command is
fixed text in this file; the user's Escape in slurp is exit 2 and the text
"cancelled by user".
"""
import base64
import io
import json
import subprocess
import sys

LONG_EDGE = 1568
THUMB_LONG = 240
THUMB_B64_MAX = 12 * 1024


def main():
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    mode = args[0] if args else "full"
    if mode not in ("full", "region"):
        print("mode must be full or region", file=sys.stderr)
        return 2
    try:
        from PIL import Image
    except ImportError:
        print("python3 PIL is not installed", file=sys.stderr)
        return 1
    if mode == "region":
        s = subprocess.run(["slurp"], capture_output=True, text=True)
        if s.returncode != 0 or not s.stdout.strip():
            print("cancelled by user", file=sys.stderr)
            return 2
        geometry = s.stdout.strip()
        g = subprocess.run(["grim", "-g", geometry, "-t", "png", "-"], capture_output=True)
    else:
        g = subprocess.run(["grim", "-t", "png", "-"], capture_output=True)
    if g.returncode != 0 or not g.stdout:
        print("grim failed: %s" % g.stderr.decode("utf-8", "replace").strip(), file=sys.stderr)
        return 1
    im = Image.open(io.BytesIO(g.stdout))
    im.load()
    full_w, full_h = im.size
    scale = min(1.0, LONG_EDGE / float(max(im.size)))
    if scale < 1.0:
        im = im.resize((max(1, round(full_w * scale)), max(1, round(full_h * scale))), Image.LANCZOS)
    if im.mode not in ("RGB", "RGBA"):
        im = im.convert("RGB")
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True)
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")

    th = im.convert("RGB")
    ts = min(1.0, THUMB_LONG / float(max(th.size)))
    if ts < 1.0:
        th = th.resize((max(1, round(th.size[0] * ts)), max(1, round(th.size[1] * ts))), Image.LANCZOS)
    q = 80
    thumb = ""
    while q >= 20:
        tb = io.BytesIO()
        th.save(tb, format="JPEG", quality=q, optimize=True)
        thumb = base64.b64encode(tb.getvalue()).decode("ascii")
        if len(thumb) <= THUMB_B64_MAX:
            break
        q -= 10
    sys.stdout.write(json.dumps({"w": im.size[0], "h": im.size[1], "fullW": full_w, "fullH": full_h,
                                 "b64": b64, "thumbB64": thumb}) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
