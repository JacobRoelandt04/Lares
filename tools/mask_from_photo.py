#!/usr/bin/env python3
"""
mask_from_photo.py -- recover a MARK's silhouette from a full-colour raster
illustration, so tools/bake_logo_relief.py can carve it.

Why this exists
---------------
The baker never looks at colour: `rasterise()` returns the alpha channel and
`bake()` binarises it, so a source is usable only if its ALPHA is the mark.
That is true of a brand SVG and false of a painting -- an illustration on an
opaque disc has a DISC for an alpha, and bakes into a featureless dome that
fails the module's own flatness gate (NOTFLAT 5
against MIN_SPREAD 6.0, measured on exactly this file with `--raw-alpha`).

What the artwork does carry is a hard tonal split.  In the Ornith avatar the
luminance inside the disc is sharply bimodal -- 65% of pixels below 0.30,
31% above 0.70, 0.9% in the whole of the middle -- so a plain threshold
recovers the illustrator's own contour with no tracing and no redrawing.  It
is stable, not knife-edge: baked at 0.35 / 0.45 / 0.55 / 0.65 the depth ramp
moves by at most 0.64 of one 8-bit level in the mean and 5 at p99, so any
threshold in that range is the same asset.

No vectoriser is used, and that is measured rather than assumed: a potrace
round-trip (threshold -> inverted PBM -> `potrace -s` -> bake) changes the
baked depth ramp by 0.25 levels in the mean and 2 at p99, because the source
disc is 1045 px and the bake's fine grid is 320 * 4 * 0.82 = 1049 -- the
raster already carries every bit of resolution the bake keeps.

WHICH TONE IS THE INK
`--ink light` (the default) makes the bright pixels the mark, so the bird
stands in relief.  `--ink dark` makes the hoodie and the disc the mark, which
scores fine and looks wrong: the figure becomes a hole in a heavy pillow.
Both are renderable from here; the choice is recorded in
modules/bar/llm/components/LlmModelLogos.qml's header.

WHAT IS DROPPED
Connected components smaller than `--min-island` px, and components whose
topmost row lies below `--drop-below` of the height.  The second rule is what
removes the two hoodie drawstrings, which are real ink but read as two loose
ticks hanging under the chin once everything is one colour.  Nothing else is
edited: the contour that survives is the source's.

Usage
-----
    tools/mask_from_photo.py IN.png OUT.png [options]

    --split-gap     crop to one side of the widest empty column run (default
                    on): the Ornith source is one strip holding the avatar, a
                    wide gap, then the wordmark.  The column is DERIVED -- the
                    script refuses to guess when the widest gap is not clearly
                    the widest.
    --keep left|right   which side of that gap to keep (default left, the
                    avatar).  `--keep right --raw-alpha` is the WORDMARK,
                    whose own alpha is already the letters; it is rendered and
                    not shipped -- see LlmModelLogos.qml's header for why.
    --no-split-gap  use the whole image.
    --ink light|dark   which tone is the mark (default light).
    --threshold F   luminance split (default 0.45).
    --feather F     width of the soft crossing, in luminance (default 0.06),
                    so the mask keeps antialiasing instead of a staircase.
    --min-island N  drop components below N px (default 500).
    --drop-below F  drop components whose top row is below this fraction of
                    the height (default 0.80).
    --raw-alpha     write the crop's ALPHA as the mask, ignoring colour
                    entirely.  This is not a mark, it is the NEGATIVE CONTROL
                    for everything above: it is what the asset becomes if the
                    threshold step is dropped: the bake of it must FAIL
                    the flatness gate.
    --report        print the column runs, the luminance histogram and every
                    component with its verdict.

The output is RGBA with the coverage in A and the RGB zeroed wherever the
coverage is -- the baker crops a PNG with `Image.getbbox()`, which is the bbox
of ANY non-zero channel, so a mask painted white everywhere is not cropped at
all and bakes undersized.
"""

import argparse
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

LUMA = (0.2126, 0.7152, 0.0722)


def widest_gap_split(alpha, report=False):
    """
    The widest run of empty columns, as (first, last+1).  The Ornith source is
    an avatar, a gap, and a wordmark whose letters are separated by gaps of
    their own, so the split is only trustworthy if it is unambiguous: the
    widest run must be at least twice any other, or this raises rather than
    cropping to the wrong place.
    """
    occupied = (alpha > 0.5).any(axis=0)
    runs = []
    start = None
    for i, filled in enumerate(occupied):
        if not filled and start is None:
            start = i
        elif filled and start is not None:
            runs.append((start, i))
            start = None
    # A trailing empty run is margin, not a separator.
    if report:
        print(f"    empty column runs: {[(a, b - a) for a, b in runs]}")
    if not runs:
        raise SystemExit("--split-gap: the image has no empty column to split at")
    runs.sort(key=lambda r: r[1] - r[0], reverse=True)
    widest = runs[0][1] - runs[0][0]
    second = runs[1][1] - runs[1][0] if len(runs) > 1 else 0
    if widest < 2 * max(second, 1):
        raise SystemExit(
            f"--split-gap: widest empty run is {widest}px against {second}px for the "
            "next one -- the split is ambiguous, crop the source by hand instead")
    if runs[0][0] <= 0:
        raise SystemExit("--split-gap: the widest empty run starts at column 0")
    return runs[0]


def clean(mask, min_island, drop_below, report=False):
    """Drop specks and anything hanging below `drop_below` of the height."""
    h = mask.shape[0]
    labels, n = ndimage.label(mask > 0.5)
    if n == 0:
        raise SystemExit("threshold left no ink -- check --ink and --threshold")
    keep = np.zeros(n + 1, dtype=bool)
    for i, sl in enumerate(ndimage.find_objects(labels), start=1):
        area = int((labels[sl] == i).sum())
        top = sl[0].start / h
        keep[i] = area >= min_island and top < drop_below
        if report:
            why = "kept" if keep[i] else ("speck" if area < min_island else "hangs low")
            print(f"    island {i:2d}  area {area:7d}  top {top:.3f}  {why}")
    return mask * keep[labels]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--split-gap", dest="split", action="store_true", default=True)
    ap.add_argument("--no-split-gap", dest="split", action="store_false")
    ap.add_argument("--keep", choices=("left", "right"), default="left")
    ap.add_argument("--ink", choices=("light", "dark"), default="light")
    ap.add_argument("--threshold", type=float, default=0.45)
    ap.add_argument("--feather", type=float, default=0.06)
    ap.add_argument("--min-island", type=int, default=500)
    ap.add_argument("--drop-below", type=float, default=0.80)
    ap.add_argument("--raw-alpha", action="store_true")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    img = np.asarray(Image.open(a.src).convert("RGBA"), dtype=np.float32) / 255.0
    rgb, alpha = img[:, :, :3], img[:, :, 3]

    if a.split:
        lo, hi = widest_gap_split(alpha, a.report)
        sl = slice(0, lo) if a.keep == "left" else slice(hi, img.shape[1])
        rgb, alpha = rgb[:, sl], alpha[:, sl]
        if a.report:
            print(f"    kept the {a.keep} of the gap: columns "
                  f"{sl.start}..{sl.stop - 1} of {img.shape[1]}")

    if a.raw_alpha:
        mask = alpha
        if a.report:
            print("    --raw-alpha: colour ignored, the silhouette IS the source's alpha")
    else:
        lum = rgb[:, :, 0] * LUMA[0] + rgb[:, :, 1] * LUMA[1] + rgb[:, :, 2] * LUMA[2]
        if a.report:
            hist, edges = np.histogram(lum[alpha > 0.5], bins=10, range=(0.0, 1.0))
            total = max(1, int((alpha > 0.5).sum()))
            print("    luminance inside the silhouette:")
            for i, c in enumerate(hist):
                print(f"      {edges[i]:.1f}-{edges[i + 1]:.1f}  {100.0 * c / total:5.1f}%")
        d = (lum - a.threshold) if a.ink == "light" else (a.threshold - lum)
        # Feathered so the mask keeps the artwork's own antialiasing, and never
        # more coverage than the source itself has at that pixel.
        mask = np.minimum(np.clip(d / max(a.feather, 1e-6) + 0.5, 0.0, 1.0), alpha)
        mask = clean(mask, a.min_island, a.drop_below, a.report)

    ys, xs = np.nonzero(mask > 0.0)
    if len(ys) == 0:
        raise SystemExit("mask is empty")
    mask = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]

    h, w = mask.shape
    out = np.zeros((h, w, 4), dtype=np.uint8)
    cov = np.clip(mask * 255.0 + 0.5, 0, 255).astype(np.uint8)
    out[:, :, 3] = cov
    # White ink so the mask can be looked at, BLACK everywhere it is empty, so
    # the baker's `getbbox()` crop sees the mask's own bounds.
    out[:, :, 0] = out[:, :, 1] = out[:, :, 2] = np.where(cov > 0, 255, 0)
    Image.fromarray(out, "RGBA").save(a.dst, optimize=True)
    print(f"{a.dst}  {w}x{h}  ink {100.0 * (mask > 0.5).mean():.2f}% of the crop")


if __name__ == "__main__":
    sys.exit(main())
