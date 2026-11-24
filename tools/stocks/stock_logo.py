#!/usr/bin/env python3
"""
stock_logo.py -- fetch one stock's logo and bake it for LogoRelief.qml.

    tools/stocks/stock_logo.py SYMBOL OUTDIR [--isin X] [--image PATH]
                               [--monogram TXT] [--local FILE] [--size 192]
                               [--mono-only]

Writes into OUTDIR (all through `<name>.part` then a rename, so a reader never
sees half a file):

    <slug>.png        the relief texture (tools/bake_logo_relief.py's bake(),
                      size 192, markFraction 0.82) -- only when a logo was found
    <slug>.mono.png   a monogram baked the same way (Inter Bold) -- ALWAYS, so
                      there is something to show for a symbol with no logo and
                      for a word-mark too wide to read under 44 px
    <slug>.none       when every source answered 404 (the caller retries after
                      30 days)

and merges `{slug: {src, brand, wide, bakedAt, mono}}` into OUTDIR/index.json
(`src` is parqet-svg | parqet-png | parqet-isin | image | none | mono; `mono`
means only the monogram exists so far: a --mono-only run, or a fetch that
failed on the network -- the full bake is still wanted). Slug: every char
outside [A-Za-z0-9.-] -> "_".

`--mono-only` bakes just the monogram (the cheap half, ~0.3 s) so a row has
something to show while the logo is fetched; it never downgrades an entry
that already has a logo. With --mono-only SYMBOL may be a comma-separated
list, baked in parallel in one process (the interpreter's start-up is most of
a single bake's wall time).

Sources, first usable wins: --image (the config's own image is used INSTEAD
of the fetched one), Parqet symbol svg, Parqet symbol png 512, Parqet isin
svg. Every fetch is `curl -q -sS -f -L --compressed --max-time 20 -A
UA`, the tool's own name with a URL (Parqet's Cloudflare answers curl's own
agent and a bare `Mozilla/5.0` with 403 since 2026-11; a named agent passes).
`--local FILE` replaces the fetches with one local file (a `.404` file stands
for an HTTP 404) -- the probe and the fixture bake use it.

The mark: rendered at 1024; transparent corners -> the alpha IS the mark
(unless it covers most of the canvas: a tile with rounded corners is keyed
like an opaque one); opaque corners -> the median corner colour is the brand
colour and is keyed out (a soft key over the RGB distance). Sanity: the mark
covers 2-60 % of the canvas and its box does not touch all four edges, or the
source is refused and the next one tried. wide = the mark's aspect > 2.

Exit: 0 a logo baked, 3 none (404 / refused everywhere; the monogram is
there), 4 a network failure (nothing written but the monogram; retry later).
The last stdout line is one JSON object: slug, src, wide, brand, ms.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bake_logo_relief as relief  # noqa: E402

PARQET = "https://assets.parqet.com/logos"
UA = "lares-stocks/0.1 (https://github.com/JacobRoelandt04/Lares)"
RENDER = 1024
PAD = 0.09          # LogoRelief.markFraction 0.82 = 1 - 2 * PAD
SS = 4


def slug(sym):
    return "".join(c if (c.isalnum() and c.isascii()) or c in ".-" else "_" for c in sym)


def enc(s):
    from urllib.parse import quote
    return quote(s, safe="")


class NotFound(Exception):
    pass


class NetFail(Exception):
    pass


def fetch(url, dst):
    r = subprocess.run(["setpriv", "--pdeathsig", "TERM", "--",
                        os.environ.get("STOCK_LOGO_CURL", "curl"),
                        "-q", "-sS", "-f", "-L", "--compressed", "--max-time", "20",
                        "-A", UA, "-o", dst, url],
                       capture_output=True, text=True)
    if r.returncode == 22 and "404" in r.stderr:
        raise NotFound(url)
    if r.returncode != 0:
        raise NetFail(f"curl exit {r.returncode}: {r.stderr.strip()[:200]}")
    if os.path.getsize(dst) == 0:
        raise NotFound(url)


def load_rgba(path):
    """Any svg/png as RGBA with its longest side RENDER px."""
    with open(path, "rb") as f:
        head = f.read(512)
    if head.startswith(b"\x89PNG") or head[:3] == b"\xff\xd8\xff" or head[:4] == b"RIFF":
        img = Image.open(path).convert("RGBA")
        f = RENDER / max(img.width, img.height)
        return img.resize((max(1, round(img.width * f)), max(1, round(img.height * f))), Image.LANCZOS)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        out = tmp.name
    try:
        subprocess.run(["rsvg-convert", "--keep-aspect-ratio", "-w", str(RENDER), "-h", str(RENDER),
                        "-o", out, path], check=True, capture_output=True)
        img = Image.open(out).convert("RGBA")
        img.load()
    finally:
        os.unlink(out)
    return img


def hexcol(c):
    return "#%02X%02X%02X" % tuple(int(round(x)) for x in c[:3])


def extract(img):
    """(mask float 0..1, brand '#RRGGBB') or raises ValueError."""
    a = np.asarray(img, dtype=np.float32) / 255.0
    rgb, alpha = a[:, :, :3], a[:, :, 3]
    h, w = alpha.shape
    k = max(4, min(h, w) // 64)
    corners = [(slice(0, k), slice(0, k)), (slice(0, k), slice(w - k, w)),
               (slice(h - k, h), slice(0, k)), (slice(h - k, h), slice(w - k, w))]
    corner_alpha = np.array([alpha[c].mean() for c in corners])
    coverage_alpha = (alpha > 0.5).mean()

    if corner_alpha.max() < 0.06 and coverage_alpha <= 0.6:
        mask = alpha
        ink = alpha > 0.5
        brand = np.median(rgb[ink], axis=0) * 255 if ink.any() else np.zeros(3)
    else:
        if corner_alpha.max() < 0.06:
            # A rounded tile: the ground is sampled just inside its box.
            ys, xs = np.nonzero(alpha > 0.5)
            y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
            m = max(4, (x1 - x0) // 16)
            ring = np.concatenate([rgb[y0 + m, x0 + m:x1 - m], rgb[y1 - m, x0 + m:x1 - m],
                                   rgb[y0 + m:y1 - m, x0 + m], rgb[y0 + m:y1 - m, x1 - m]])
            bg = np.median(ring, axis=0)
        else:
            bg = np.median(np.concatenate([rgb[c].reshape(-1, 3) for c in corners]), axis=0)
        dist = np.sqrt(((rgb - bg) ** 2).sum(axis=-1)) * 255.0
        mask = np.clip((dist - 28.0) / 40.0, 0.0, 1.0) * alpha
        brand = bg * 255

    ink = mask > 0.5
    cov = ink.mean()
    if not (0.02 <= cov <= 0.60):
        raise ValueError(f"coverage {cov * 100:.1f}% outside 2-60%")
    ys, xs = np.nonzero(ink)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    if y0 <= 1 and x0 <= 1 and y1 >= h - 2 and x1 >= w - 2:
        raise ValueError("the mark touches all four edges")
    return mask[y0:y1 + 1, x0:x1 + 1], hexcol(brand)


def fit(mask, size):
    """The mark fitted into the bake's inner box on the fine grid."""
    inner = int(round(size * SS * (1.0 - 2.0 * PAD)))
    h, w = mask.shape
    f = inner / max(h, w)
    im = Image.fromarray((mask * 255).astype(np.uint8), "L")
    im = im.resize((max(1, round(w * f)), max(1, round(h * f))), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def save_png(rgb, dst):
    part = dst + ".part"
    Image.fromarray(rgb, "RGB").save(part, format="PNG", optimize=True)
    os.replace(part, dst)


def bold_font(px):
    path = subprocess.run(["fc-match", "-f", "%{file}", "Inter:bold"], capture_output=True,
                          text=True).stdout.strip()
    for i in range(0, 32):
        try:
            f = ImageFont.truetype(path, px, index=i)
        except OSError:
            break
        if f.getname()[1].lower() == "bold":
            return f
    return ImageFont.truetype(path, px)


def monogram_mask(txt):
    f = bold_font(400)
    l, t, r, b = f.getbbox(txt)
    im = Image.new("L", (r - l + 40, b - t + 40), 0)
    ImageDraw.Draw(im).text((20 - l, 20 - t), txt, font=f, fill=255)
    a = np.asarray(im, dtype=np.float32) / 255.0
    ys, xs = np.nonzero(a > 0.5)
    return a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def bake_mono(job):
    txt, size, dst = job
    save_png(relief.bake(fit(monogram_mask(txt), size), size, SS, 0.055, 0.62, 1.6), dst)


def default_monogram(sym):
    base = sym.lstrip("^").split(".")[0].split("=")[0].split("-")[0]
    letters = "".join(c for c in base if c.isalnum())
    return (letters[:2] or "?").upper()


def read_index(outdir):
    try:
        with open(os.path.join(outdir, "index.json")) as f:
            idx = json.load(f)
        return idx if isinstance(idx, dict) else {}
    except (OSError, ValueError):
        return {}


def merge_index(outdir, key, entry):
    path = os.path.join(outdir, "index.json")
    idx = read_index(outdir)
    idx[key] = entry
    part = path + ".part"
    with open(part, "w") as f:
        json.dump(idx, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(part, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("symbol")
    ap.add_argument("outdir")
    ap.add_argument("--isin", default="")
    ap.add_argument("--image", default="")
    ap.add_argument("--monogram", default="")
    ap.add_argument("--local", default="")
    ap.add_argument("--size", type=int, default=192)
    ap.add_argument("--mono-only", action="store_true")
    a = ap.parse_args()

    t0 = time.monotonic()
    os.makedirs(a.outdir, exist_ok=True)
    key = slug(a.symbol)

    if a.mono_only:
        syms = [s for s in a.symbol.split(",") if s] if "," in a.symbol else [a.symbol]
        texts = [a.monogram or default_monogram(syms[0])] if len(syms) == 1 else [default_monogram(s) for s in syms]
        jobs = [(t, a.size, os.path.join(a.outdir, slug(s) + ".mono.png")) for s, t in zip(syms, texts)]
        if len(jobs) == 1:
            bake_mono(jobs[0])
        else:
            from multiprocessing import Pool
            with Pool(min(len(jobs), os.cpu_count() or 2)) as pool:
                pool.map(bake_mono, jobs)
        for s in syms:
            old = read_index(a.outdir).get(slug(s))
            if not old or old.get("src") in (None, "", "mono"):
                merge_index(a.outdir, slug(s), {"src": "mono", "brand": "", "wide": False,
                                                "bakedAt": int(time.time() * 1000), "mono": True})
        print(json.dumps({"slug": ",".join(slug(s) for s in syms), "src": "mono",
                          "ms": int((time.monotonic() - t0) * 1000)}))
        return 0

    sources = []
    if a.image:
        sources.append(("image", a.image, None))
    if a.local:
        sources.append(("parqet-" + ("isin" if a.isin and a.isin in os.path.basename(a.local) else
                                     "png" if a.local.lower().endswith(".png") else "svg"), None, a.local))
    else:
        sources.append(("parqet-svg", None, f"{PARQET}/symbol/{enc(a.symbol)}?format=svg"))
        sources.append(("parqet-png", None, f"{PARQET}/symbol/{enc(a.symbol)}?format=png&size=512"))
        if a.isin:
            sources.append(("parqet-isin", None, f"{PARQET}/isin/{enc(a.isin)}?format=svg"))

    result = {"slug": key, "src": "none", "wide": False, "brand": "", "why": []}
    netfail = False
    with tempfile.TemporaryDirectory() as tmp:
        for name, path, where in sources:
            try:
                if path is None:
                    if a.local:
                        if where.endswith(".404"):
                            raise NotFound(where)
                        path = where
                    else:
                        path = os.path.join(tmp, name)
                        fetch(where, path)
                mask, brand = extract(load_rgba(path))
            except NotFound:
                result["why"].append(f"{name}: 404")
                continue
            except NetFail as e:
                result["why"].append(f"{name}: {e}")
                netfail = True
                continue
            except (ValueError, OSError, subprocess.CalledProcessError) as e:
                result["why"].append(f"{name}: {e}")
                continue
            h, w = mask.shape
            rgb = relief.bake(fit(mask, a.size), a.size, SS, 0.055, 0.62, 1.6)
            save_png(rgb, os.path.join(a.outdir, key + ".png"))
            result.update(src=name, wide=bool(w / max(1, h) > 2.0), brand=brand)
            break

    mono = a.monogram or default_monogram(a.symbol)
    save_png(relief.bake(fit(monogram_mask(mono), a.size), a.size, SS, 0.055, 0.62, 1.6),
             os.path.join(a.outdir, key + ".mono.png"))

    none_path = os.path.join(a.outdir, key + ".none")
    if result["src"] == "none" and not netfail:
        with open(none_path + ".part", "w") as f:
            f.write(str(int(time.time() * 1000)) + "\n")
        os.replace(none_path + ".part", none_path)
    elif result["src"] != "none" and os.path.exists(none_path):
        os.unlink(none_path)

    if result["src"] != "none" or not netfail:
        merge_index(a.outdir, key, {"src": result["src"], "brand": result["brand"], "wide": result["wide"],
                                    "bakedAt": int(time.time() * 1000), "mono": True})
    else:
        # A network failure: the monogram is there, the logo still wanted.
        old = read_index(a.outdir).get(key)
        if not old or old.get("src") in (None, "", "mono"):
            merge_index(a.outdir, key, {"src": "mono", "brand": "", "wide": False,
                                        "bakedAt": int(time.time() * 1000), "mono": True})
    result["ms"] = int((time.monotonic() - t0) * 1000)
    print(json.dumps(result))
    if result["src"] != "none":
        return 0
    return 4 if netfail else 3


if __name__ == "__main__":
    sys.exit(main())
