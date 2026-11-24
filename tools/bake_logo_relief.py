#!/usr/bin/env python3
"""
bake_logo_relief.py -- turn a logo SVG into the ONE texture LogoRelief.qml
needs to carve that logo into the shell's surface at runtime.

Why bake at all
---------------
The shell's carved look (ShadowBox) is a light bevel just OUTSIDE an edge and
an inset shadow just INSIDE it.  Following a *logo's* contour instead of a
rounded box means knowing, per pixel, how far the nearest edge is and in which
direction it lies.  Both are distance-transform work: expensive on the CPU,
impossible to do honestly in a fragment shader from an alpha mask alone (the
usual `(alpha-0.5)/fwidth(alpha)` trick only measures the first pixel of a
blurred edge, so a stroke thinner than the shadow reads as uniformly dark).

So the whole distance problem is solved ONCE, here, offline, and the runtime is
one textured quad.

What is in the texture
----------------------
The file is written as an OPAQUE RGB png, deliberately.  Qt uploads an image
that has an alpha channel as PREMULTIPLIED, which multiplies every other
channel by that alpha -- so a coverage mask in A would silently zero the
normal and the ramp everywhere outside the mark, and the outer bevel would
vanish without a warning anywhere.  Three channels, no alpha, nothing to
premultiply by:

    R, G  the unit normal of the signed distance field, biased to 0..1.
          It points TOWARD the interior of the mark, and it is continuous
          across the contour (it comes from the *signed* field, not from dIn
          alone), so mipmapping it does not tear at the edge.
          +G is DOWN, matching Qt's texture coordinates.

    B     one signed ramp with the contour at 0.5, in units of the carve depth:
              inside   0.5 + 0.5 * clamp(dIn  / depthEff, 0, 1)  -> 1.0 at the floor
              outside  0.5 - 0.5 * clamp(dOut / depth,    0, 1)  -> 0.0 one depth out
          The outside half runs over the same `depth`, not over a baked bevel
          width, so B is locally a plain signed distance: the shader recovers
          the silhouette's antialiasing from its own screen-space gradient
          (the length of (dFdx, dFdy) -- one device pixel in every direction,
          where `fwidth` would be 1.41 of one on a diagonal), which is exact
          under any scale, and the outer bevel becomes a runtime
          fraction of the depth rather than something frozen into the asset.
          The inside half is the island-corrected ramp -- see below.

Where the contour lies
----------------------
The field is computed at `--ss` times the texture's resolution and area-
averaged down to it.  Binarising a mask AT texture resolution puts the contour
on the texel grid, and the distance transform of that staircase is a
staircase: at 320 px shown at 170 the seam wobbled by up to half a texel
(a third of a screen pixel) along every curve and every diagonal, which is
what read as aliasing.  A signed ramp is linear on both sides of the contour
with the same slope, so the area average of the fine field is EXACT, and the
contour it encodes sits at the fine grid's precision -- 1/ss of a texel --
with no wobble for the runtime to reproduce.  Same texture size, same
runtime cost; only the bake works harder.

The island rule
---------------
`depthEff = min(depth, core * thick)`, where `thick` is a local maximum of the
inside distance -- the half-width of the limb a pixel sits in.  A limb narrower
than the shadow therefore gets a SHALLOWER carve rather than being swallowed by
it: the ramp still reaches its floor in the middle of the stroke, so a hairline
keeps a lit core instead of going flat dark.

The maximum is taken over a disc of radius depth/core (not depth): a point one
pixel inside a *thick* shape must still see `thick >= depth/core`, or every
thick edge would be shallowed too.  It is computed on a downsampled copy --
thickness is a smooth field and the disc dilation is the only slow step.

Usage
-----
    tools/bake_logo_relief.py IN.svg OUT.png [options]

    --size N        texture edge, px (default 320)
    --pad F         empty margin as a fraction of the edge (default 0.09)
    --depth F       carve depth as a fraction of the edge (default 0.055)
    --core F        island rule: fraction of a limb's half-width the carve may
                    use before it must flatten out (default 0.62)
    --smooth F      sigma, in texture px, for smoothing the field the normal is
                    taken from (default 1.6)
    --ss N          supersampling: the field is computed at N times the
                    texture's resolution and averaged down (default 4)
    --report        print field statistics (island rule effect, coverage)

PNG input is accepted too (its alpha is used, fitted to the same box an SVG
would fill), for a mark that has no SVG.
"""

import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage


def rasterise(path, inner):
    """Alpha mask of `path` fitted into an inner x inner box, as float 0..1."""
    if path.lower().endswith(".svg"):
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            out = tmp.name
        try:
            subprocess.run(
                ["rsvg-convert", "--keep-aspect-ratio",
                 "-w", str(inner), "-h", str(inner), "-o", out, path],
                check=True, capture_output=True)
            img = Image.open(out).convert("RGBA")
            img.load()
        finally:
            os.unlink(out)
    else:
        img = Image.open(path).convert("RGBA")
        img = img.crop(img.getbbox() or (0, 0, img.width, img.height))
        f = inner / max(img.width, img.height)
        img = img.resize((max(1, round(img.width * f)), max(1, round(img.height * f))),
                         Image.LANCZOS)

    a = np.asarray(img, dtype=np.float32)[:, :, 3] / 255.0
    if a.max() <= 0:
        raise SystemExit(f"{path}: rasterised to nothing (empty alpha)")
    return a


def thickness(d_in, radius):
    """
    Local maximum of `d_in` over a disc of `radius` -- the half-width of the
    limb each pixel sits in.  Computed on a downsampled copy because the field
    is smooth and a full-resolution disc dilation is the only slow step here.
    """
    # Keep the downsampled disc around a dozen px across: big enough to be a
    # disc rather than a plus sign, small enough to be instant.
    step = max(1, int(round(radius / 12.0)))
    small = d_in[::step, ::step] if step > 1 else d_in
    r = max(1, int(round(radius / step)))
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    disc = (xx * xx + yy * yy) <= r * r
    grown = ndimage.grey_dilation(small, footprint=disc, mode="constant", cval=0.0)
    if step > 1:
        grown = ndimage.zoom(grown, (d_in.shape[0] / grown.shape[0],
                                     d_in.shape[1] / grown.shape[1]), order=1)
        grown = grown[:d_in.shape[0], :d_in.shape[1]]
        # zoom's bilinear can undershoot the true maximum at the seams; the
        # thickness can never be less than the pixel's own distance.
        grown = np.maximum(grown, d_in)
    return grown


def bake(alpha, size, ss, depth_f, core, sigma, report=False):
    # Everything below happens on the FINE grid: `size * ss` texels a side,
    # the depth and the smoothing sigma scaled to match. The last step
    # averages the packed field down to `size`.
    size = size * ss
    depth = depth_f * size
    sigma = sigma * ss

    canvas = np.zeros((size, size), dtype=np.float32)
    h, w = alpha.shape
    y0 = (size - h) // 2
    x0 = (size - w) // 2
    canvas[y0:y0 + h, x0:x0 + w] = alpha
    alpha = canvas

    inside = alpha > 0.5
    if not inside.any():
        raise SystemExit("mask has no pixel above half coverage")

    d_in = ndimage.distance_transform_edt(inside)
    d_out = ndimage.distance_transform_edt(~inside)
    # The contour lies between the last inside pixel and the first outside one,
    # so both distances are half a pixel long at the seam.
    sd = np.where(inside, d_in - 0.5, -(d_out - 0.5)).astype(np.float32)

    # ---- island rule ----------------------------------------------------
    thick = thickness(d_in, depth / max(core, 1e-3))
    depth_eff = np.minimum(depth, core * thick)
    depth_eff = np.maximum(depth_eff, 1.0)

    ramp_in = np.clip(np.maximum(d_in - 0.5, 0.0) / depth_eff, 0.0, 1.0)
    ramp_out = np.clip(np.maximum(d_out - 0.5, 0.0) / depth, 0.0, 1.0)
    b = np.where(inside, 0.5 + 0.5 * ramp_in, 0.5 - 0.5 * ramp_out).astype(np.float32)

    # ---- normal ----------------------------------------------------------
    # From the SIGNED field so it is continuous across the contour; smoothed
    # first, because the EDT of a rasterised edge is a staircase at pixel scale
    # and its raw gradient speckles.
    sm = ndimage.gaussian_filter(sd, sigma=sigma)
    gy, gx = np.gradient(sm)          # row-major: gy is DOWN, matching Qt's v axis
    mag = np.sqrt(gx * gx + gy * gy)
    ok = mag > 1e-4
    nx = np.where(ok, gx / np.where(ok, mag, 1.0), 0.0)
    ny = np.where(ok, gy / np.where(ok, mag, 1.0), 0.0)

    rgb = np.stack([
        np.clip(0.5 + 0.5 * nx, 0, 1),
        np.clip(0.5 + 0.5 * ny, 0, 1),
        np.clip(b, 0, 1),
    ], axis=-1)

    if ss > 1:
        # Area average. Exact for the ramp (linear either side of the seam);
        # the normal's average is shorter than unit wherever the fine normals
        # disagree inside one texel, so it is renormalised afterwards.
        rgb = rgb.reshape(size // ss, ss, size // ss, ss, 3).mean(axis=(1, 3))
        n = rgb[:, :, :2] * 2.0 - 1.0
        mag = np.sqrt((n * n).sum(axis=-1, keepdims=True))
        n = np.where(mag > 1e-4, n / np.maximum(mag, 1e-4), 0.0)
        rgb[:, :, :2] = 0.5 + 0.5 * n

    if report:
        lim = inside & (core * thick < depth)
        frac = 100.0 * lim.sum() / max(1, inside.sum())
        # How much of the mark reaches its floor: without the island rule a
        # thin limb never would.
        naive = np.clip(np.maximum(d_in - 0.5, 0.0) / depth, 0, 1)
        print(f"    ink {100.0 * inside.mean():5.2f}% of canvas | "
              f"limbs shallowed {frac:5.1f}% of ink | "
              f"floor reached {100.0 * (ramp_in[inside] > 0.99).mean():5.1f}% "
              f"(without the rule {100.0 * (naive[inside] > 0.99).mean():5.1f}%) | "
              f"depth {depth / ss:.1f}px "
              f"islands {ndimage.label(inside)[1]}")

    return (rgb * 255.0 + 0.5).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--size", type=int, default=320)
    ap.add_argument("--pad", type=float, default=0.09)
    ap.add_argument("--depth", type=float, default=0.055)
    ap.add_argument("--core", type=float, default=0.62)
    ap.add_argument("--smooth", type=float, default=1.6)
    ap.add_argument("--ss", type=int, default=4)
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    ss = max(1, a.ss)
    inner = int(round(a.size * ss * (1.0 - 2.0 * a.pad)))
    alpha = rasterise(a.src, inner)
    rgb = bake(alpha, a.size, ss, a.depth, a.core, a.smooth, a.report)
    Image.fromarray(rgb, "RGB").save(a.dst, optimize=True)
    print(f"{a.dst}  {a.size}x{a.size}  {os.path.getsize(a.dst) / 1024.0:.0f} KiB"
          f"  markFraction {1.0 - 2.0 * a.pad:.2f}  (LogoRelief.markFraction must match)")


if __name__ == "__main__":
    sys.exit(main())
