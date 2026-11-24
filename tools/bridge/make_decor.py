#!/usr/bin/env python3
"""make_decor.py -- what a phone's body is dressed in, as the seven textures the body's shader reads.

    tools/bridge/make_decor.py                 writes modules/bridge/assets/<skin>_<kind>.png for every skin
    tools/bridge/make_decor.py <skin> ...      only these
    tools/bridge/make_decor.py --check         fails when a committed texture is not what the tables now draw
    tools/bridge/make_decor.py --preview <dir> also writes <dir>/<skin>_preview.png: the back and the walls, flatly lit

A dev-time generator (the PNGs are committed; nothing runs it at run time). What it draws is laid out from the
measurements in modules/bridge/body/BodyGeometry.js (`SKINS[...]`, millimetres): the user's photos of the phone were
MEASURED (feedback/phone_photos/, git-ignored), and what they show is drawn here from those numbers; no photo is read
or copied. One exception, by the user's own call: the chip maker's flame and word on the duct's badge are that
maker's published mark, taken as a stencil and stored as outlines (tools/bridge/decor_paths.json). The badge's two
figures are set in Montserrat and its strip in Inter (fc-match: on a machine without them `--check` reads STALE).

UNDER THE BACK GLASS (one texel is 1/PX mm of the body's back, the whole w x h, corner to corner):
  <skin>_albedo.png   the colour of what is there, with the shade its own relief casts on it
  <skin>_relief.png   R, G the surface's normal (x, y; 0.5 is flat); B how deep it lies under the glass (0 .. DEPTH_MAX mm):
                      the shader shifts what it reads by the eye's angle and this depth, which is what makes a lens
                      sink and the glass read as glass when the phone turns
  <skin>_grain.png    R, G which way a surface's fine grooves run and how strong they are (the direction's DOUBLE angle
                      times the strength, 0.5 = none: brushed metal, turned metal, the ruled plates), so a level
                      between two directions is less grain and never a third direction; B where the shader rules the
                      fine lines themselves and how strongly they show (the plate's 0.5, the window's rings and the
                      field's stripes more, a printed film over them less: a texture of lines would shimmer)
  <skin>_film.png     R where the printed film lies (the line art, the wordmark, the pill, the mark): the shader reads
                      it once more towards the light, for the shadow the film casts on the plate; G where the back is
                      BARE (no glass over it: a metal shell)
  <skin>_surface.png  R the roughness (0 a mirror .. 1 matte), G what lights up (the fan's ring, the emblem, the mark:
                      lit by the shader while the phone is busy), B metal (1) or paint and plastic (0)
THE FRAME (four strips, one per wall, each the wall's length x the body's thickness at FRAME_PX texels per mm, stacked
right / left / top / bottom with GUTTER texels between, the end walls at the left; along a side wall y runs down, along
an end wall x runs as the front is seen; across, the front glass's edge comes first). The shader reads it WITHOUT mip
levels: a wall is read inside a branch and on the silhouette, where a pixel's neighbour may not have a wall's
coordinate at all and the level the GPU picks is then anybody's guess (the cached body and the live one differed). So
it is drawn near the size it is seen at, where one bilinear read is enough:
  <skin>_frame.png        the colour: the metal, the keys, the triggers, the vents, the antenna's lines, every hole
  <skin>_frameRelief.png  R, G the normal (along, across), B the roughness
Linear weights, so a mip level between two materials is a blend of them and never a third material. EVERY texture is
opaque: Qt hands an Image to a shader premultiplied, so a value kept in alpha would scale the other three.
"""
import json
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GEOM = os.path.join(ROOT, "modules/bridge/body/BodyGeometry.js")
OUTDIR = os.path.join(ROOT, "modules/bridge/assets")
PX = 12            # texels per mm of what lies under the back glass (BodyLayer.qml's decorPx)
FRAME_PX = 8       # ... of the frame's walls (BodyLayer.qml's framePx): near the size they are seen at, see below
HI = 2             # supersampling while drawing
DEPTH_MAX = 3.0    # mm: the relief's B channel covers 0 .. this (BodyLayer.qml's decorDepthMm)
GUTTER = 8         # texels between the frame's strips (BodyLayer.qml's frameGutter)
KINDS = ("albedo", "relief", "grain", "surface", "film", "frame", "frameRelief")


def skins():
    js = "const fs=require('fs');const s=fs.readFileSync(process.argv[1],'utf8').replace(/^\\.pragma.*$/m,'');" \
         "process.stdout.write(new Function(s+';return json();')());"
    return json.loads(subprocess.check_output(["node", "-e", js, GEOM]))


def font(pattern, px):
    f = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout.strip()
    return ImageFont.truetype(f, max(4, int(round(px))))


def shade(c, k):
    return [min(1.0, v * k) for v in c]


def smooth(a, lo, hi):
    t = np.clip((a - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


class Canvas:
    """Float layers over a w x h mm rectangle, drawn in millimetres from its centre (x right, y down)."""

    def __init__(self, w, h, seed=7, px=PX):
        self.w, self.h = w, h
        self.k = px * HI
        self.W = int(round(w * px)) * HI
        self.H = int(round(h * px)) * HI
        z = lambda v: np.full((self.H, self.W), v, np.float32)
        self.rgb = np.zeros((self.H, self.W, 3), np.float32)
        self.rough, self.metal = z(0.5), z(0.0)
        self.z = z(0.0)                    # mm: 0 the glass's underside (or a wall's own face), negative deeper
        self.calm = z(0.0)                 # where a step has NO slope: a part with no bevel of its own (a printed film's
                                           # edge, a well's wall) keeps its depth and its shade but catches no light
        self.sink = z(0.0)                 # mm deeper still, for the eye's angle only: no slope, no shade (a lens's barrel)
        self.gx, self.gy = z(0.0), z(0.0)  # the grooves' double-angle vector times their strength
        self.lines, self.glow = z(0.0), z(0.0)
        self.film = z(0.0)                 # where a printed film lies over the surface (it casts a shadow on what is under it)
        self.bare = z(0.0)                 # where NO glass lies over the surface (a metal shell)
        self.proud = z(0.0)                # mm a part of the BODY stands out of the back (the shader's own geometry: a
                                           # camera plateau). Shade only: what lies beside it is in its shade
        self.rng = np.random.default_rng(seed)
        self._xx = self._yy = None

    # ---- coordinates ----
    def _px(self, x, y):
        return ((x + self.w / 2) * self.k, (y + self.h / 2) * self.k)

    def grid(self):
        """Every texel's centre in mm (cached)."""
        if self._xx is None:
            xs = (np.arange(self.W, dtype=np.float32) + 0.5) / self.k - self.w / 2
            ys = (np.arange(self.H, dtype=np.float32) + 0.5) / self.k - self.h / 2
            self._xx, self._yy = np.meshgrid(xs, ys)
        return self._xx, self._yy

    @staticmethod
    def box(m, pad=0):
        """The slices of what `m` covers, grown by `pad` texels (None when it covers nothing)."""
        rows = np.flatnonzero(m.max(axis=1) > 0.004)
        cols = np.flatnonzero(m.max(axis=0) > 0.004)
        if rows.size == 0:
            return None
        return (slice(max(0, rows[0] - pad), min(m.shape[0], rows[-1] + 1 + pad)),
                slice(max(0, cols[0] - pad), min(m.shape[1], cols[-1] + 1 + pad)))

    # ---- masks (float 0..1 at the drawing resolution) ----
    def _mask(self, draw):
        im = Image.new("L", (self.W, self.H), 0)
        draw(ImageDraw.Draw(im))
        return np.asarray(im, np.float32) / 255.0

    def rrect(self, x0, y0, x1, y1, r=0.0):
        a, b = self._px(x0, y0), self._px(x1, y1)
        r = max(0.0, min(r, (x1 - x0) / 2, (y1 - y0) / 2))
        return self._mask(lambda d: d.rounded_rectangle([a[0], a[1], b[0] - 1, b[1] - 1], radius=r * self.k, fill=255))

    def pill(self, x0, y0, x1, y1):
        return self.rrect(x0, y0, x1, y1, min(x1 - x0, y1 - y0) / 2)

    def circle(self, x, y, r):
        c = self._px(x, y)
        return self._mask(lambda d: d.ellipse([c[0] - r * self.k, c[1] - r * self.k, c[0] + r * self.k - 1, c[1] + r * self.k - 1], fill=255))

    def poly(self, pts):
        return self._mask(lambda d: d.polygon([self._px(x, y) for x, y in pts], fill=255))

    @staticmethod
    def fillet(pts, closed=True, steps=10):
        """A path of (x, y, r) with each corner turned at its radius r (0: sharp); convex and concave alike."""
        out = []
        n = len(pts)
        for i, (x, y, r) in enumerate(pts):
            if r <= 0 or (not closed and i in (0, n - 1)):
                out.append((x, y))
                continue
            ax, ay = pts[(i - 1) % n][0] - x, pts[(i - 1) % n][1] - y
            bx, by = pts[(i + 1) % n][0] - x, pts[(i + 1) % n][1] - y
            la, lb = math.hypot(ax, ay), math.hypot(bx, by)
            ax, ay, bx, by = ax / la, ay / la, bx / lb, by / lb
            half = math.acos(max(-1.0, min(1.0, ax * bx + ay * by))) / 2
            if half < 1e-3 or half > math.pi / 2 - 1e-3:
                out.append((x, y))
                continue
            d = min(r / math.tan(half), la * 0.5, lb * 0.5)
            rr = d * math.tan(half)
            mx, my = ax + bx, ay + by
            ml = math.hypot(mx, my)
            cx, cy = x + mx / ml * rr / math.sin(half), y + my / ml * rr / math.sin(half)
            a0 = math.atan2(y + ay * d - cy, x + ax * d - cx)
            a1 = math.atan2(y + by * d - cy, x + bx * d - cx)
            da = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
            for k in range(steps + 1):
                a = a0 + da * k / steps
                out.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        return out

    def rpoly(self, pts):
        """A polygon of (x, y, r): each corner turned at its own radius."""
        return self.poly(self.fillet(pts))

    def line(self, pts, width):
        return self._mask(lambda d: d.line([self._px(x, y) for x, y in pts], fill=255, width=max(1, int(round(width * self.k))), joint="curve"))

    def ring(self, x, y, r0, r1):
        return np.clip(self.circle(x, y, r1) - self.circle(x, y, r0), 0, 1)

    def soften(self, m, mm):
        """Round a mask's corners, inward and outward alike, by about `mm`."""
        b = self.box(m, int(3 * mm * self.k) + 2)
        out = np.zeros_like(m)
        if b is not None:
            out[b] = smooth(ndimage.gaussian_filter(m[b], mm * self.k * 0.6), 0.5 - 0.5 / (mm * self.k), 0.5 + 0.5 / (mm * self.k))
        return out

    def grow(self, m, mm):
        """A mask's outline moved out (in, for a negative `mm`)."""
        b = self.box(m, int(abs(mm) * self.k) + 3)
        out = np.zeros_like(m)
        if b is not None:
            inside = m[b] > 0.5
            d = ndimage.distance_transform_edt(~inside) - ndimage.distance_transform_edt(inside)
            out[b] = np.clip(0.5 - (d - mm * self.k), 0, 1)
        return out

    def text(self, s, x, y, size_mm, pattern="Inter:bold", turn=0, spacing=0.0):
        """`s` centred at x, y; `turn` 90 reads bottom to top; `spacing` extra mm between letters."""
        f = font(pattern, size_mm * self.k)
        widths = [f.getlength(ch) for ch in s]
        gap = spacing * self.k
        tw = int(math.ceil(sum(widths) + gap * (len(s) - 1))) + 8
        asc, desc = f.getmetrics()
        im = Image.new("L", (tw, asc + desc + 8), 0)
        d = ImageDraw.Draw(im)
        cx = 4.0
        for ch, w in zip(s, widths):
            d.text((cx, 4), ch, font=f, fill=255)
            cx += w + gap
        box = im.getbbox()
        if box:
            im = im.crop(box)
        if turn:
            im = im.rotate(turn, expand=True, resample=Image.BICUBIC)
        full = Image.new("L", (self.W, self.H), 0)
        c = self._px(x, y)
        full.paste(im, (int(round(c[0] - im.width / 2)), int(round(c[1] - im.height / 2))))
        return np.asarray(full, np.float32) / 255.0

    def text_span(self, s, x0, x1, y, pattern="Inter:bold", spacing=0.0):
        """`s` set so that it runs from x0 to x1, centred on y."""
        ref = font(pattern, 200)
        wide = sum(ref.getlength(ch) for ch in s) / 200.0           # the word's width in ems
        size = (x1 - x0 - spacing * (len(s) - 1)) / wide
        return self.text(s, (x0 + x1) / 2, y, size, pattern=pattern, spacing=spacing)

    def text_box(self, s, x0, y0, x1, y1, pattern="Inter:bold"):
        """`s` set so that its ink fills the box x0..x1, y0..y1 (the letters keep their own widths)."""
        f = font(pattern, 6.0 * self.k)
        im = Image.new("L", (int(f.getlength(s)) + 80, int(8.0 * self.k)), 0)
        ImageDraw.Draw(im).text((40, int(self.k)), s, font=f, fill=255)
        im = im.crop(im.getbbox())
        a, b = self._px(x0, y0), self._px(x1, y1)
        im = im.resize((max(1, int(round(b[0] - a[0]))), max(1, int(round(b[1] - a[1])))), Image.LANCZOS)
        full = Image.new("L", (self.W, self.H), 0)
        full.paste(im, (int(round(a[0])), int(round(a[1]))))
        return np.asarray(full, np.float32) / 255.0

    # ---- paint ----
    def paint(self, m, rgb=None, rough=None, metal=None, lines=None, glow=None, grain=None):
        """`grain`: (angle in degrees from +x towards +y, strength), or None to leave it; (0, 0) clears it."""
        b = self.box(m)
        if b is None:
            return
        mm = m[b]
        if rgb is not None:
            self.rgb[b] += (np.asarray(rgb, np.float32)[None, None, :] - self.rgb[b]) * mm[:, :, None]
        for name, v in (("rough", rough), ("metal", metal), ("lines", lines), ("glow", glow)):
            if v is not None:
                a = getattr(self, name)
                a[b] += (v - a[b]) * mm
        if grain is not None:
            th = math.radians(grain[0]) * 2.0
            self.gx[b] += (math.cos(th) * grain[1] - self.gx[b]) * mm
            self.gy[b] += (math.sin(th) * grain[1] - self.gy[b]) * mm

    def glaze(self, m, rgb, k, rough, metal, lines):
        """A thin film over what `m` covers: the colour goes `k` of the way to the film's, the surface is the film's
        own, and the ruled lines under it still show, `lines` as strongly."""
        b = self.box(m)
        if b is None:
            return
        mm = m[b]
        self.rgb[b] += (np.asarray(rgb, np.float32)[None, None, :] - self.rgb[b]) * (mm * k)[:, :, None]
        self.rough[b] += (rough - self.rough[b]) * mm
        self.metal[b] += (metal - self.metal[b]) * mm
        self.lines[b] *= 1.0 - (1.0 - lines) * mm
        self.film[b] = np.maximum(self.film[b], mm)

    def grain_round(self, m, x, y, strength):
        """Grooves that run ROUND a centre (turned metal): the light on them is a pair of spokes."""
        b = self.box(m)
        if b is None:
            return
        xx, yy = self.grid()
        th = 2.0 * (np.arctan2(yy[b] - y, xx[b] - x) + math.pi / 2)
        self.gx[b] += (np.cos(th) * strength - self.gx[b]) * m[b]
        self.gy[b] += (np.sin(th) * strength - self.gy[b]) * m[b]

    def grain_along(self, m, dist, strength):
        """Grooves that follow the contours of a distance field (rings inside a rounded box)."""
        b = self.box(m, 2)
        if b is None:
            return
        gy, gx = np.gradient(ndimage.gaussian_filter(dist[b], 1.0))
        th = 2.0 * (np.arctan2(gy, gx) + math.pi / 2)
        self.gx[b] += (np.cos(th) * strength - self.gx[b]) * m[b]
        self.gy[b] += (np.sin(th) * strength - self.gy[b]) * m[b]

    # ---- relief ----
    def _ramp(self, m, bevel):
        b = self.box(m, 2)
        if b is None:
            return None, None
        inside = ndimage.distance_transform_edt(m[b] > 0.5) / self.k
        return b, np.clip(inside / max(bevel, 1e-3), 0, 1)

    def level(self, m, z, bevel, relief=True):
        """Bring what `m` covers to elevation `z` (mm; negative is deeper), its edge a slope `bevel` mm wide. With
        `relief` False the step is depth and shade only: it has no slope, so its edge catches no light."""
        b, t = self._ramp(m, bevel)
        if b is None:
            return
        self.z[b] += (z - self.z[b]) * t
        if relief:                                           # a part with an edge of its own brings it back
            keep = self.grow(m, 0.12)
            kb = self.box(keep)
            self.calm[kb] *= 1.0 - keep[kb]
        else:
            w = bevel + 0.16
            band = np.clip(self.grow(m, w) - self.grow(m, -w), 0, 1)
            bb = self.box(band)
            self.calm[bb] = np.maximum(self.calm[bb], band[bb])

    def edge(self, m, dz, bevel, share):
        """Barely an edge: what `m` covers stands `dz` proud over a slope `bevel` wide, and `share` of that slope is
        left to catch the light."""
        self.lift(m, dz, bevel)
        band = np.clip(self.grow(m, 0.12) - self.grow(m, -bevel - 0.12), 0, 1)
        bb = self.box(band)
        if bb is not None:
            self.calm[bb] = np.minimum(self.calm[bb], 1.0 - share * band[bb])

    def lift(self, m, dz, bevel):
        b, t = self._ramp(m, bevel)
        if b is not None:
            self.z[b] += dz * t

    def dome(self, x, y, r, height):
        m = self.circle(x, y, r)
        b = self.box(m)
        if b is None:
            return
        xx, yy = self.grid()
        d2 = ((xx[b] - x) ** 2 + (yy[b] - y) ** 2) / (r * r)
        self.z[b] += height * np.sqrt(np.clip(1 - d2, 0, 1))

    def bowl(self, x, y, r, height):
        """A shallow paraboloid: `height` at the centre, 0 at r, a gentle even slope (a lens's front, an eye)."""
        m = self.circle(x, y, r)
        b = self.box(m)
        if b is None:
            return
        xx, yy = self.grid()
        d2 = ((xx[b] - x) ** 2 + (yy[b] - y) ** 2) / (r * r)
        self.z[b] += height * np.clip(1 - d2, 0, 1)

    def cone(self, x, y, r, height, layer="z"):
        """A cone's flank: `height` at the centre, 0 at r (a negative height: a dish). `layer` "sink": depth only."""
        m = self.circle(x, y, r)
        b = self.box(m)
        if b is None:
            return
        xx, yy = self.grid()
        d = np.sqrt((xx[b] - x) ** 2 + (yy[b] - y) ** 2) / r
        getattr(self, layer)[b] += height * np.clip(1 - d, 0, 1)

    # ---- out ----
    def _down(self, a):
        if a.ndim == 2:
            return a.reshape(self.H // HI, HI, self.W // HI, HI).mean(axis=(1, 3))
        return a.reshape(self.H // HI, HI, self.W // HI, HI, a.shape[2]).mean(axis=(1, 3))

    def normals(self, blur=0.7):
        h = ndimage.gaussian_filter(self.z, blur * HI)
        gy, gx = np.gradient(h, 1.0 / self.k)          # mm per mm
        still = 1.0 - np.clip(ndimage.gaussian_filter(self.calm, 0.5 * HI), 0, 1)
        n = np.stack([-gx * still, -gy * still, np.ones_like(gx)], axis=2)
        n /= np.linalg.norm(n, axis=2, keepdims=True)
        return n

    def occlusion(self, gain=0.55, floor=0.58):
        """How much of the room each point sees: what lies under its surroundings is in their shade."""
        z = self.z + self.proud
        ao = np.ones_like(z)
        for sigma, g in ((0.35, gain), (1.1, gain * 0.7)):
            around = ndimage.gaussian_filter(z, sigma * self.k)
            ao *= 1.0 - np.clip((around - z) * g / max(sigma, 0.5), 0, 1 - floor)
        return np.clip(ao, floor, 1.0)

    def settled(self, n, pixel_mm=0.2):
        """The roughness with the relief's own fineness in it: where the normal turns within one pixel of the screen
        (a bevel's edge, a ridge) a mirror would flash single pixels as the phone moves; a surface that fine is, to
        the eye, a rougher one (the mean normal's shortfall from unit length is how much it turns)."""
        mean = np.stack([ndimage.gaussian_filter(n[:, :, i], pixel_mm * 0.5 * self.k) for i in range(3)], axis=2)
        short = np.clip(1.0 - np.linalg.norm(mean, axis=2), 0, 1)
        return np.sqrt(np.clip(self.rough ** 2 + 2.2 * short, 0, 1))

    @staticmethod
    def byte(a):
        return np.clip(np.rint(a * 255.0), 0, 255).astype(np.uint8)

    def back_images(self):
        n = self.normals(0.9)
        ao = self.occlusion()
        b = lambda a: self.byte(self._down(a))
        albedo = b(self.rgb * ao[:, :, None])
        relief = np.dstack([b(n[:, :, 0] * 0.5 + 0.5), b(n[:, :, 1] * 0.5 + 0.5), b((self.sink - self.z) / DEPTH_MAX)])
        grain = np.dstack([b(self.gx * 0.5 + 0.5), b(self.gy * 0.5 + 0.5), b(self.lines)])
        surface = np.dstack([b(self.settled(n)), b(self.glow), b(self.metal)])
        film = b(ndimage.gaussian_filter(self.film, 0.04 * self.k))          # (its edge a touch soft: a shadow's edge is)
        return {"albedo": Image.fromarray(albedo, "RGB"), "relief": Image.fromarray(relief, "RGB"),
                "grain": Image.fromarray(grain, "RGB"), "surface": Image.fromarray(surface, "RGB"),
                "film": Image.fromarray(np.dstack([film, b(self.bare), np.zeros_like(film)]), "RGB")}

    def wall_arrays(self):
        n = self.normals(0.8)
        ao = self.occlusion(0.8, 0.35)
        b = lambda a: self.byte(self._down(a))
        return b(self.rgb * ao[:, :, None]), np.dstack([b(n[:, :, 0] * 0.5 + 0.5), b(n[:, :, 1] * 0.5 + 0.5), b(self.settled(n))])


# =====================================================================================================================
# the frame's walls
# =====================================================================================================================

HOLE = [0.012, 0.012, 0.015]


def wall(sk, length, parts, seed):
    """One wall: `length` mm along (from its centre) x the body's thickness across (the front glass's edge first)."""
    t = sk["t"]
    s = Canvas(length, t, seed, FRAME_PX)
    base = sk["frame"]
    s.rgb[:] = np.asarray(base, np.float32)
    s.rough[:] = 0.40
    s.metal[:] = 1.0
    half = t / 2
    for p in parts:
        kind = p["kind"]
        if kind == "antenna":
            m = s.rrect(p["at"] - 0.4, -half, p["at"] + 0.4, half, 0)
            s.paint(m, rgb=[0.055, 0.057, 0.065], rough=0.35, metal=0.0)
            s.level(m, -0.03, 0.1)
        elif kind == "trigger":                              # a capacitive trigger: frosted glass let into the frame
            a, b = p["a"], p["b"]
            m = s.pill(a, -2.5, b, 2.5)
            s.paint(s.grow(m, 0.14), rgb=shade(base, 0.42), rough=0.5)
            s.paint(m, rgb=[0.90, 0.905, 0.92], rough=0.78, metal=0.0)
            s.level(s.grow(m, 0.14), -0.10, 0.12)
            s.level(m, -0.05, 0.3)
            mid = (a + b) / 2
            s.paint(s.pill(mid - 3.3, -0.27, mid + 3.3, 0.27), rgb=[0.74, 0.75, 0.78], rough=0.55)   # the strip its light shines through
        elif kind == "vent":                                 # the fan's slot (measured off the side photo: 3.05 mm across, its
            a, b = p["a"], p["b"]                            # centre piece 1.15): a pill cut straight into the frame, a slim bar down
            hs, hb = 1.52, 0.57                              # its middle at the frame's own height, held by four thin bridges that
            m = s.pill(a, -hs, b, hs)                        # lie LOWER than it. Hardly a bevel anywhere.
            mid = (a + b) / 2
            bar = s.pill(a + 1.25, -hb, b - 1.25, hb)
            ring = np.clip(m - bar, 0, 1)
            bridges = np.zeros_like(m)
            for bx in (mid - 4.95, mid + 4.95):
                bridges = np.maximum(bridges, s.rrect(bx - 0.28, -hs - 0.1, bx + 0.28, hs + 0.1, 0))
            bridges *= ring
            gaps = s.soften(np.clip(ring - bridges, 0, 1), 0.2)                  # the openings' ends are a little round
            s.paint(ring, rgb=shade(base, 0.74), rough=0.45)                     # the bridges (and a hair of each opening's wall): in the slot's shade
            s.level(ring, -0.38, 0.05, relief=False)
            s.paint(gaps, rgb=[0.03, 0.03, 0.036], rough=0.6, metal=0.0)
            s.level(gaps, -1.6, 0.2, relief=False)
            fins = np.zeros_like(m)
            for i in range(int((b - a) / 0.42)):             # the fan's fins, deep inside
                x = a + 0.4 + i * 0.42
                fins = np.maximum(fins, s.rrect(x, -hs, x + 0.13, hs, 0))
            s.paint(fins * gaps, rgb=[0.085, 0.087, 0.095])
            s.paint(bar, rgb=shade(base, 1.02), rough=0.36)
            s.edge(bar, 0.02, 0.07, 0.5)
        elif kind == "rocker" or kind == "bar":              # a key: the frame's own metal, in a cut of its own
            a, b = p["a"], p["b"]
            hz = p.get("hz", 1.05)
            rocker = kind == "rocker"                        # (the rocker: flat nearly to its edge, in a tight cut)
            m = s.rrect(a, -hz, b, hz, hz * 0.78) if rocker else s.rrect(a, -hz, b, hz, 0.25)
            cut = s.grow(m, 0.11 if rocker else 0.13)
            s.paint(cut, rgb=shade(base, 0.36), rough=0.5)
            s.paint(m, rgb=shade(base, 1.03), rough=0.32)
            s.level(cut, -0.12, 0.1)
            s.level(m, 0.05, 0.13 if rocker else 0.3)
        elif kind == "power":                                # round: a polished bevel, a FLAT ring of turned ridges (the shader
            x, r = p["at"], p["r"]                           # rules them), and only inside the innermost ridge a shallow dish
            s.paint(s.circle(x, 0, r + 0.15), rgb=shade(base, 0.34), rough=0.5)
            s.level(s.circle(x, 0, r + 0.15), -0.14, 0.1, relief=False)
            m = s.circle(x, 0, r)
            s.paint(m, rgb=shade(base, 1.04), rough=0.24)
            s.level(m, 0.06, 0.2)
            s.paint(s.ring(x, 0, r * 0.86, r), rgb=shade(base, 1.10), rough=0.10)
            dish = s.circle(x, 0, r * 0.42)
            s.paint(dish, rgb=shade(base, 0.99), rough=0.42)
            s.bowl(x, 0, r * 0.42, -0.16)
        elif kind == "slider":                               # the red switch: it fills its slot but for one end, where the
            a, b = p["a"], p["b"]                            # slot's own floor shows (the frame's metal, in the slot's shade)
            slot = s.pill(a, -1.6, b, 1.6)
            s.paint(slot, rgb=shade(base, 0.60), rough=0.5)
            s.level(slot, -0.5, 0.2, relief=False)
            key = s.pill(a + 1.25, -1.56, b - 0.04, 1.56) * slot
            s.paint(key, rgb=sk["accent"], rough=0.22, metal=1.0)
            s.level(key, 0.02, 0.3)
            for i in range(6):                               # its grooves, on the slant: barely there
                x = a + 2.6 + i * 1.12
                g = s.line([(x - 0.85, 1.4), (x + 0.85, -1.4)], 0.30) * key
                s.paint(g, rgb=shade(sk["accent"], 0.94))
        elif kind == "mic":                                  # (`off`: mm from the wall's middle towards the back; the front is negative)
            m = s.circle(p["at"], p.get("off", 0.0), 0.42)
            s.paint(m, rgb=HOLE, rough=0.7, metal=0.0)
            s.level(m, -0.8, 0.15)
        elif kind == "grille":
            a, b, n = p["a"], p["b"], p["n"]
            off = p.get("off", 0.0)
            for i in range(n):
                x = a + (b - a) * i / (n - 1)
                m = s.circle(x, off, 0.80)
                s.paint(m, rgb=HOLE, rough=0.7, metal=0.0)
                s.level(m, -1.0, 0.22)
                s.paint(s.circle(x, off, 0.5), rgb=[0.05, 0.05, 0.058])     # the mesh behind
        elif kind == "ir":                                   # the infrared window: dark glass, a little red in it
            m = s.circle(p["at"], 0, 1.1)
            s.paint(m, rgb=[0.07, 0.035, 0.045], rough=0.08, metal=0.0)
            s.level(m, -0.06, 0.15)
        elif kind == "jack":
            x = p["at"]
            m = s.circle(x, 0, 2.2)
            s.paint(m, rgb=[0.075, 0.077, 0.085], rough=0.4, metal=0.0)
            s.level(m, -0.25, 0.2)
            inner = s.circle(x, 0, 1.72)
            s.paint(inner, rgb=HOLE, rough=0.6)
            s.level(inner, -2.0, 0.3)
            s.paint(s.ring(x, 0, 1.0, 1.3), rgb=[0.14, 0.13, 0.11], rough=0.3, metal=1.0)     # a contact, deep down
        elif kind == "usb":
            x, w = p["at"], p["w"]
            m = s.pill(x - w / 2, -1.65, x + w / 2, 1.65)
            s.paint(m, rgb=[0.07, 0.072, 0.08], rough=0.45, metal=0.0)
            s.level(m, -0.2, 0.2)
            inner = s.pill(x - w / 2 + 0.55, -1.2, x + w / 2 - 0.55, 1.2)
            s.paint(inner, rgb=HOLE, rough=0.6)
            s.level(inner, -2.2, 0.3)
            s.paint(s.rrect(x - 3.2, -0.32, x + 3.2, 0.32, 0.1), rgb=[0.16, 0.16, 0.18], rough=0.4)    # the tongue
        elif kind == "sim":
            a, b = p["a"], p["b"]
            m = s.pill(a, -1.5, b, 1.5)
            seam = np.clip(s.grow(m, 0.07) - s.grow(m, -0.07), 0, 1)
            s.paint(seam, rgb=shade(base, 0.40), rough=0.5)
            s.lift(seam, -0.08, 0.05)
            hole = s.circle(a + 1.2 if abs(a) > abs(b) else b - 1.2, 0, 0.42)
            s.paint(hole, rgb=HOLE, rough=0.7, metal=0.0)
            s.level(hole, -0.8, 0.15)
    return s.wall_arrays()


def frame_images(sk):
    """The four walls stacked: right, left, top, bottom."""
    walls = sk.get("walls")
    if walls is None:
        # a skin with no table of its own: its keys, as bars
        walls = {"right": [], "left": [], "top": [], "bottom": [{"kind": "usb", "at": sk["port"]["x"], "w": sk["port"]["w"]}]}
        for k in sk["keys"]:
            walls["right" if k["side"] > 0 else "left"].append({"kind": "bar", "a": k["y0"], "b": k["y1"], "hz": k.get("hz", 0.17 * sk["t"])})
    aw, sh = int(round(sk["h"] * FRAME_PX)), int(round(sk["t"] * FRAME_PX))
    ah = 4 * sh + 3 * GUTTER
    base = Canvas.byte(np.asarray(sk["frame"], np.float32))
    albedo = np.empty((ah, aw, 3), np.uint8)
    albedo[:] = base
    relief = np.empty((ah, aw, 3), np.uint8)
    relief[:] = (128, 128, 102)
    for row, (name, length) in enumerate((("right", sk["h"]), ("left", sk["h"]), ("top", sk["w"]), ("bottom", sk["w"]))):
        a, r = wall(sk, length, walls[name], 11 + row)
        y = row * (sh + GUTTER)
        albedo[y:y + sh, 0:a.shape[1]] = a
        relief[y:y + sh, 0:a.shape[1]] = r
        # the strip's own edge rows run on into the gutters, so a level of the mip chain never reads the ground there
        for g in range(1, GUTTER // 2 + 1):
            if y - g >= 0:
                albedo[y - g, 0:a.shape[1]] = a[0]
                relief[y - g, 0:a.shape[1]] = r[0]
            if y + sh - 1 + g < ah:
                albedo[y + sh - 1 + g, 0:a.shape[1]] = a[-1]
                relief[y + sh - 1 + g, 0:a.shape[1]] = r[-1]
    return {"frame": Image.fromarray(albedo, "RGB"), "frameRelief": Image.fromarray(relief, "RGB")}


# =====================================================================================================================
# the user's phone: REDMAGIC 10S Pro, the transparent back
# =====================================================================================================================

# The colours of what lies under the glass (the object's own paint, as the photos show it in daylight).
def pale(c, k=0.045):
    """A blue taken a little towards white (the user's eye: the first blues were a shade too strong)."""
    return [v + (1.0 - v) * k for v in c]


CHROME = [0.74, 0.76, 0.80]
BOX = [0.40, 0.42, 0.47]            # the camera boxes: matte anodised
# between the parts: a knurled sheet. Its ground is bare metal (it mirrors the room: seen straight on under a light
# it is pale and the points barely stand out; seen from the side it darkens and they do), its points are matte
GROUND = [0.53, 0.56, 0.605]
POINT = [0.93, 0.96, 0.98]
PANE = pale([0.55, 0.73, 0.88])     # the blue pane round the X
FIELD = pale([0.53, 0.705, 0.855])
WINDOW = pale([0.57, 0.75, 0.89])
EMBLEM = [0.46, 0.47, 0.51]
DUCT = [0.45, 0.47, 0.515]          # the air duct: brushed
BADGE = [0.86, 0.875, 0.90]
PLATE = pale([0.62, 0.76, 0.90])    # the lined plate
FILM = [0.40, 0.43, 0.49]           # what is printed on it: a thin silvery film the plate's lines show through
SCREW = [0.40, 0.41, 0.445]         # steel, turned flat
BLACK = [0.030, 0.031, 0.036]
TURNED = [0.095, 0.096, 0.108]      # black metal turned in fine rings (a lens's bezel, the fan's housing)
GLASS = [0.012, 0.015, 0.026]       # lens glass: black, with the coating's blue in what it mirrors

# The emblem in the window, traced on a 10 x 10 grid (the unit is the skin's `emblem.ux` x `uy` mm): one hook; the
# other is this one turned half round about the centre. And one blade; its twin likewise.
EMBLEM_C = (5.02, 4.70)
EMBLEM_HOOK = [(0.55, 1.28), (3.97, 1.28), (5.33, 2.98), (4.88, 3.52), (3.55, 2.12), (2.12, 2.12), (4.14, 4.27), (5.02, 4.27),
               (5.02, 5.13), (4.02, 5.13)]
EMBLEM_BLADE = [(6.05, 3.05), (9.25, 0.25), (6.55, 3.65)]

# The mark at the plate's foot, on a 10 x 10 grid about x = 5.3: the left half's bars (the right half mirrors them).
MARK_AXIS = 5.3
MARK_BARS = [
    [(2.05, 2.00), (2.75, 2.20), (2.85, 3.90), (2.00, 3.70)],
    [(1.15, 3.40), (2.00, 3.65), (2.05, 4.15), (2.85, 4.90), (3.00, 6.50), (3.30, 7.95), (2.75, 7.30), (2.30, 6.00), (1.95, 4.60), (1.60, 3.90)],
    [(3.70, 0.50), (4.55, 0.95), (4.65, 4.05), (3.85, 4.10)],
    [(3.95, 4.65), (4.70, 4.55), (4.80, 7.00), (5.05, 9.40), (4.55, 8.30), (4.10, 6.80)],
    [(3.85, 4.10), (4.65, 4.05), (6.65, 4.60), (5.90, 4.62)],
]


def badge_paths():
    """The chip badge's outlines (tools/bridge/decor_paths.json): the flame and the word, in the badge's own box."""
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "decor_paths.json")) as f:
        return json.load(f)


# The wordmark's letters, drawn (ours, after the phone's own, letter by letter off the user's close-ups): heavy
# strokes ST of the cap height, every right angle sharp, only the bowls' outer corners turned. Each letter in a box
# 1 tall (v up from the foot) and `width` wide: ("bar", u0, v0, u1, v1) a rectangle; ("leg", u0, v0, u1, v1) a slanted
# stroke from one point to the other, cut level at both ends; ("turn", cu, cv, r, quadrant) a quarter ring of outer
# radius r about (cu, cv), quadrant 0 = up and right, 1 = up and left, 2 = down and left, 3 = down and right.
ST = 0.175
RB, RD = 0.24, 0.40         # the R's bowl; the D's, G's and C's
_MID = 0.5 - ST / 2
LETTERS = {
    # no stem above its waist: the head bar and the waist bar end free at the left
    "R": (1.27, [("bar", 0, 1 - ST, 1.27 - RB, 1), ("turn", 1.27 - RB, 1 - RB, RB, 0), ("bar", 1.27 - ST, _MID + RB, 1.27, 1 - RB),
                 ("turn", 1.27 - RB, _MID + RB, RB, 3), ("bar", 0, _MID, 1.27 - RB, _MID + ST), ("bar", 0, 0, ST, _MID + ST),
                 ("leg", 0.74, _MID, 1.27 - ST * 0.62, 0)]),
    # three bars; a stem only below the waist
    "E": (1.30, [("bar", 0, 1 - ST, 1.30, 1), ("bar", 0, _MID, 1.17, _MID + ST), ("bar", 0, 0, 1.30, ST), ("bar", 0, 0, ST, _MID + ST)]),
    "D": (1.25, [("bar", 0, 0, ST, 1), ("bar", 0, 1 - ST, 1.25 - RD, 1), ("bar", 0, 0, 1.25 - RD, ST), ("turn", 1.25 - RD, 1 - RD, RD, 0),
                 ("turn", 1.25 - RD, RD, RD, 3), ("bar", 1.25 - ST, RD, 1.25, 1 - RD)]),
    "M": (1.56, [("bar", 0, 0, ST, 1), ("bar", 1.56 - ST, 0, 1.56, 1), ("leg", ST * 0.62, 1, 0.78, 0), ("leg", 1.56 - ST * 0.62, 1, 0.78, 0)]),
    "A": (1.45, [("leg", 0.725, 1, ST * 0.62, 0), ("leg", 0.725, 1, 1.45 - ST * 0.62, 0)]),
    # a D turned round, less the upper half of its stem
    "G": (1.27, [("bar", RD, 1 - ST, 1.27, 1), ("bar", RD, 0, 1.27, ST), ("turn", RD, 1 - RD, RD, 1), ("turn", RD, RD, RD, 2),
                 ("bar", 0, RD, ST, 1 - RD), ("bar", 1.27 - ST, 0, 1.27, 0.5)]),
    "I": (ST, [("bar", 0, 0, ST, 1)]),
    # a D turned round, less its stem
    "C": (1.27, [("bar", RD, 1 - ST, 1.27, 1), ("bar", RD, 0, 1.27, ST), ("turn", RD, 1 - RD, RD, 1), ("turn", RD, RD, RD, 2),
                 ("bar", 0, RD, ST, 1 - RD)]),
}


def wordmark(s, W):
    """The word up the plate's left, reading from the foot to the head (the letters' heads to the left)."""
    cap = W["cap"]
    widths = [LETTERS[ch][0] * cap for ch in W["text"]]
    gap = (W["y1"] - W["y0"] - sum(widths)) / (len(widths) - 1)
    m = np.zeros_like(s.lines)
    along = W["y1"]                                          # the first letter stands at the foot

    def at(u, v):                                            # a letter's (u along the word, v up) -> the sheet
        return (W["x"] + cap / 2 - v * cap, along - u * cap)

    for ch, wd in zip(W["text"], widths):
        for part in LETTERS[ch][1]:
            if part[0] == "bar":
                _, u0, v0, u1, v1 = part
                pts = [at(u0, v0), at(u1, v0), at(u1, v1), at(u0, v1)]
            elif part[0] == "leg":
                _, u0, v0, u1, v1 = part
                h = ST * 0.5 * math.hypot(u1 - u0, v1 - v0) / abs(v1 - v0)      # half its width along the line of writing
                pts = [at(u0 - h, v0), at(u0 + h, v0), at(u1 + h, v1), at(u1 - h, v1)]
            else:
                _, cu, cv, r, quad = part
                a0 = quad * math.pi / 2
                arc = [(math.cos(a0 + k * math.pi / 32), math.sin(a0 + k * math.pi / 32)) for k in range(17)]
                pts = [at(cu + r * c, cv + r * sn) for c, sn in arc] + [at(cu + (r - ST) * c, cv + (r - ST) * sn) for c, sn in reversed(arc)]
            m = np.maximum(m, s.poly(pts))
        along -= wd + gap
    return m


def lens(s, L, collar):
    """A main camera: the bright collar that joins its box to the glass (the shader hides it under the glass's black
    print unless the eye looks in from the side), then a FLAT ring of black metal turned in fine circles (its light is
    a faint pair of spokes), a wide matte black shoulder that gives almost nothing back, and the lens itself."""
    x, y, r = L["x"], L["y"], L["r"]
    rb, rg = L.get("bezel", r * 0.85), L.get("glass", r * 0.5)
    rim = s.ring(x, y, r - 0.05, r + collar)
    s.paint(rim, rgb=[0.74, 0.75, 0.78], rough=0.16, metal=1.0, grain=(0, 0))
    s.level(s.circle(x, y, r + collar), -0.12, 0.3, relief=False)
    disc = s.circle(x, y, r)
    s.paint(disc, rgb=TURNED, rough=0.24, metal=1.0, grain=(0, 0))
    s.level(disc, -0.30, 0.2, relief=False)
    s.grain_round(disc, x, y, 0.9)
    for sgn in (-1, 1):                                      # the bezel's two marks, at its head and its foot
        s.paint(s.rrect(x - 0.16, y + sgn * (r + rb) / 2 - 0.36, x + 0.16, y + sgn * (r + rb) / 2 + 0.36, 0.1) * disc, rgb=[0.17, 0.172, 0.19], rough=0.3, grain=(0, 0))
    shoulder = s.circle(x, y, rb)
    s.paint(shoulder, rgb=[0.011, 0.011, 0.013], rough=0.97, metal=0.0, grain=(0, 0))
    s.cone(x, y, rb, 2.4, "sink")                            # the barrel sinks towards its middle (the eye's angle only)
    glass = s.circle(x, y, rg)
    s.paint(glass, rgb=BLACK, rough=0.05)
    s.bowl(x, y, rg, 0.30)                                   # the front element bulges: it catches the room's light as a crescent
    for rr, wd, c in ((0.80, 0.06, [0.085, 0.087, 0.10]), (0.56, 0.07, [0.10, 0.102, 0.116])):
        s.paint(s.ring(x, y, rg * rr - wd, rg * rr + wd), rgb=c, rough=0.22)
    eye = s.circle(x, y, rg * 0.38)
    s.paint(eye, rgb=GLASS, rough=0.03)
    s.dome(x, y, rg * 0.38, 0.18)
    s.paint(s.circle(x, y, rg * 0.14), rgb=[0.006, 0.006, 0.008], rough=0.03)


def screw(s, x, y):
    """A screw down in its well: a FLAT head of turned steel (its light is a pair of spokes, not an edge), a small
    six-pointed socket."""
    well = s.circle(x, y, 1.22)
    s.paint(well, rgb=[0.17, 0.175, 0.20], rough=0.55, metal=0.4, lines=0.0, glow=0.0, grain=(0, 0))
    s.level(well, -1.50, 0.12, relief=False)
    head = s.circle(x, y, 1.02)
    s.paint(head, rgb=SCREW, rough=0.20, metal=1.0)
    s.level(head, -1.25, 0.06, relief=False)
    s.grain_round(head, x, y, 0.95)
    star = []
    for i in range(12):
        a = i * math.pi / 6 + 0.2
        rr = 0.40 if i % 2 == 0 else 0.20
        star.append((x + rr * math.cos(a), y + rr * math.sin(a)))
    sock = s.poly(star)
    s.paint(sock, rgb=[0.06, 0.06, 0.075], rough=0.5, grain=(0, 0))


def redmagic(sk):
    B = sk["back"]
    s = Canvas(sk["w"], sk["h"])
    C = B["chrome"]
    xx, yy = s.grid()

    # ---- what the mirror border leaves open --------------------------------------------------------------------------
    TL = B["tabLeft"]
    inner = s.rrect(C["x0"], C["y0"], C["x1"], C["y1"], C["r"])
    tab = s.poly([(C["x0"] - 1, TL["y0"]), (C["x0"], TL["y0"]), (TL["x"], TL["y0"] + TL["ramp"]), (TL["x"], TL["y1"] - TL["ramp"]),
                  (C["x0"], TL["y1"]), (C["x0"] - 1, TL["y1"])])
    inner = np.clip(inner - tab, 0, 1)

    # ---- the knurled sheet the upper parts lie in: matte points, one a millimetre, on bare metal. Towards the border
    # at the head and at the right the sheet dips under it: a slope the light catches, where the points give out, then
    # bare and lower (not at the left, nor along the duct) -------------------------------------------------------------
    D, K = B["duct"], B["knurl"]
    upper = inner * (yy < D["y0"] + 1.2)
    s.paint(upper, rgb=GROUND, rough=0.50, metal=0.85)
    s.level(upper, -1.05, 0.01, relief=False)
    b = s.box(upper)
    def fall(d, flat):                                       # 1 down in the dip, 0 up on the sheet
        return 1.0 - smooth(d, flat, flat + K["slope"])
    dip = np.maximum(fall(yy[b] - C["y0"], K["dipTop"]), fall(C["x1"] - xx[b], K["dipRight"])) * upper[b]
    s.z[b] -= K["drop"] * dip
    s.rgb[b] *= (1.0 - 0.30 * dip)[:, :, None]                 # ... and in the border's shade
    pitch = K["pitch"]
    def lozenge(px, py):                                     # a point of the knurl: a rounded lozenge
        dx, dy = np.abs(px - np.round(px)) * pitch, np.abs(py - np.round(py)) * pitch
        return (dx ** 1.5 + dy ** 1.5) ** (1 / 1.5)
    px, py = xx[b] / pitch, yy[b] / pitch
    dots = (1.0 - smooth(np.minimum(lozenge(px, py), lozenge(px - 0.5, py - 0.5)), 0.20, 0.27)) * upper[b] * (1.0 - smooth(dip, 0.05, 0.55))
    s.rgb[b] += (np.asarray(POINT, np.float32)[None, None, :] - s.rgb[b]) * dots[:, :, None]
    s.rough[b] += (0.70 - s.rough[b]) * dots
    s.metal[b] += (0.0 - s.metal[b]) * dots

    # ---- the camera boxes and their lenses ----------------------------------------------------------------------------
    # one piece of matte metal, a hair deeper than the knurled sheet, its edges tight; the lower box stands a little
    # over the upper one, so the line between them is a ridge of the metal itself
    for i, R in enumerate(B["boxes"]):
        box = s.rrect(R["x0"], R["y0"], R["x1"], R["y1"], 0.25) * inner
        s.paint(box, rgb=shade(BOX, 1.0 if i else 1.05), rough=0.46, metal=1.0, grain=(0, 0))
        s.level(box, -1.05 - B["boxDrop"] + (B["boxRidge"] if i else 0.0), B["boxBevel"])
    for L in B["lenses"]:
        lens(s, L, B["collar"])

    # ---- the blue pane's outline (drawn further down): the duct keeps clear of it -------------------------------------
    P = B["pane"]
    st = P["step"]
    pane = s.rpoly([(P["x0"], P["y0"], P["rLeft"]), (P["x1"], P["y0"], P["rTopRight"] + 0.5), (P["x1"], P["y1"], P["rFootRight"]),
                    (st["x1"], P["y1"], 1.6), (st["x0"], st["y"], 1.6), (P["x0"], st["y"], P["rLeft"])])
    for x, y, hidden in B["screws"]:                         # the pane is cut round the screws on its edge
        pane = np.clip(pane - s.circle(x, y, 1.55), 0, 1)
    pane = s.soften(pane, 0.3) * inner

    # ---- the duct: brushed metal across, its foot a step lower at the left; at the right its head rises to the screw
    # there, ROUND the pane's corner and a slit clear of it -- the knurled sheet runs on through that slit -----------------
    ds, rise = D["step"], D["rise"]
    turn = P["x1"] - P["rFootRight"]                         # where the pane's foot starts to turn up
    duct = s.rpoly([(D["x0"] - 1, D["y0"], 0), (turn, D["y0"], 0), (turn, rise["y"], 0), (D["x1"] + 1, rise["y"], 0),
                    (D["x1"] + 1, D["y1"], 0), (ds["x1"], D["y1"], 0.5), (ds["x0"], ds["y"], 0.5), (D["x0"] - 1, ds["y"], 0)]) * inner
    duct = np.clip(duct - s.grow(pane, rise["gap"]), 0, 1)
    s.paint(duct, rgb=DUCT, rough=0.27, metal=1.0, lines=0.0, grain=(0, 1.0))
    s.level(duct, -0.40, 0.07)
    b = s.box(duct)
    streak = ndimage.gaussian_filter(s.rng.standard_normal(s.rgb[b].shape[:2]).astype(np.float32), (0.55, 70.0))
    streak /= max(1e-6, float(np.abs(streak).max()))
    s.rgb[b] *= (1.0 + 0.13 * streak * duct[b])[:, :, None]

    # the fan: a FLAT housing of black metal turned in fine rings (three lugs), the open ring the blades show through
    # (more light gets down there than one would think), the turned hub on its two bridges, the red eye
    F = B["fan"]
    fx, fy, fr = F["x"], F["y"], F["r"]
    housing = s.circle(fx, fy, fr)
    for deg in (90, 210, 330):                               # its three lugs
        a = math.radians(deg)
        ca, sa = math.cos(a), math.sin(a)
        c0, c1 = fr - 0.6, fr + 0.66                         # each a little wedge, narrower at its tip
        housing = np.maximum(housing, s.poly([(fx + ca * c0 - sa * 0.95, fy + sa * c0 + ca * 0.95), (fx + ca * c1 - sa * 0.52, fy + sa * c1 + ca * 0.52),
                                              (fx + ca * c1 + sa * 0.52, fy + sa * c1 - ca * 0.52), (fx + ca * c0 + sa * 0.95, fy + sa * c0 - ca * 0.95)]))
    s.paint(housing, rgb=TURNED, rough=0.22, metal=1.0, grain=(0, 0))
    s.level(housing, -0.16, 0.06, relief=False)
    s.grain_round(s.circle(fx, fy, fr), fx, fy, 0.9)
    well = s.ring(fx, fy, F["hub"], F["well"])
    s.paint(well, rgb=[0.105, 0.108, 0.122], rough=0.5, metal=0.0, glow=0.75, grain=(0, 0))
    s.level(s.circle(fx, fy, F["well"]), -2.3, 0.3, relief=False)
    blades = np.zeros_like(well)
    for i in range(46):
        a = i * 2 * math.pi / 46
        blades = np.maximum(blades, s.line([(fx + (F["hub"] - 0.1) * math.cos(a), fy + (F["hub"] - 0.1) * math.sin(a)),
                                            (fx + (F["well"] + 0.1) * math.cos(a + 0.16), fy + (F["well"] + 0.1) * math.sin(a + 0.16))], 0.12))
    s.paint(blades * well, rgb=[0.235, 0.24, 0.265], rough=0.4)
    s.paint(s.ring(fx, fy, F["well"] - 0.22, F["well"]), rgb=[0.20, 0.20, 0.23], glow=1.0)
    hub = s.circle(fx, fy, F["hub"])
    hub = np.maximum(hub, s.rrect(fx - 0.3, fy - F["well"] - 0.4, fx + 0.3, fy - F["hub"] + 0.4, 0))      # the two bridges that hold the hub
    hub = np.maximum(hub, s.rrect(fx - 0.3, fy + F["hub"] - 0.4, fx + 0.3, fy + F["well"] + 0.4, 0))
    hub *= housing
    s.paint(hub, rgb=[0.085, 0.086, 0.095], rough=0.16, metal=1.0, glow=0.0)
    s.level(hub, -0.55, 0.25, relief=False)
    s.cone(fx, fy, F["hub"], 0.32)
    s.grain_round(s.circle(fx, fy, F["hub"]), fx, fy, 1.0)
    dot = s.circle(fx, fy, F["eye"])
    s.paint(dot, rgb=[0.86, 0.07, 0.10], rough=0.20, metal=1.0)
    s.cone(fx, fy, F["eye"], 0.16)
    s.grain_round(dot, fx, fy, 1.0)

    # the chip's badge: a square of the duct ROUGHENED (it scatters the light). The flame, the word and the figures are
    # what was left alone: the duct's own brushed metal, grain and all
    G = B["badge"]
    badge = s.rrect(G["x0"], G["y0"], G["x1"], G["y1"], 0.15)
    gw, gh = G["x1"] - G["x0"], G["y1"] - G["y0"]
    marks = badge_paths()
    def filled(subs):                                        # even-odd
        m = np.zeros(badge.shape, bool)
        for sub in subs:
            m ^= s.poly([(G["x0"] + gw * u, G["y0"] + gh * v) for u, v in sub]) > 0.5
        return s.soften(m.astype(np.float32), 0.05)
    left = np.maximum(filled(marks["flame"]), filled(marks["word"]))
    eight = s.text_box("8", G["x0"] + 0.975, G["y0"] + 6.875, G["x0"] + 2.5, G["y0"] + 9.375, pattern="Montserrat:medium")
    left = np.maximum(left, np.clip(eight - s.grow(eight, -0.16), 0, 1))                          # the figure is an outline
    left = np.maximum(left, s.text_box("Elite", G["x0"] + 0.94, G["y0"] + 9.81, G["x0"] + 3.94, G["y0"] + 10.81, pattern="Montserrat:semibold"))
    fr = G["frame"]                                          # a border of the roughened metal all round: the flame stops short of the duct
    left *= s.rrect(G["x0"] + fr, G["y0"] + fr, G["x1"] - fr, G["y1"] - fr, 0.05)
    St = G["strip"]
    strip = s.rrect(G["x0"], St["y0"], G["x1"], St["y1"], 0.1)
    rough_marks = np.clip(strip - s.rrect(G["x0"] + 0.13, St["y0"] + 0.13, G["x1"] - 0.13, St["y1"] - 0.13, 0.05), 0, 1)
    rough_marks = np.maximum(rough_marks, s.text_span("LEADING VERSION", G["x0"] + 0.55, G["x1"] - 0.55, (St["y0"] + St["y1"]) / 2, pattern="Inter:bold", spacing=0.16))
    rough_marks = np.maximum(rough_marks, badge * (1.0 - left))
    s.paint(rough_marks, rgb=BADGE, rough=0.85, metal=0.35, grain=(0, 0))
    s.lift(rough_marks, -G["sunk"], G["bevel"])                # the roughening took a little metal off: a faint slope down into it
    b = s.box(rough_marks, 2)                                # ... and left it uneven: cloudy in its roughness and its shade
    own = np.random.default_rng(23)                          # (its own dice: what is drawn after it keeps its noise)
    cloud = ndimage.gaussian_filter(own.standard_normal(s.rgb[b].shape[:2]).astype(np.float32), 0.16 * s.k)
    cloud += 1.6 * ndimage.gaussian_filter(own.standard_normal(cloud.shape).astype(np.float32), 0.05 * s.k)
    cloud /= max(1e-6, float(np.abs(cloud).max()))
    s.rough[b] = np.clip(s.rough[b] + 0.18 * cloud * rough_marks[b], 0, 1)
    s.rgb[b] *= (1.0 + 0.10 * cloud * rough_marks[b])[:, :, None]

    # ---- the blue pane: in the knurled sheet, FLUSH with it, a hair's gap all round and hardly an edge. On it, flush
    # too, the striped field (no edge at all: its outline is one more of its own light lines), and sunk into that the
    # window, ring within ring, with the emblem ------------------------------------------------------------------------
    slit = np.clip(s.grow(pane, 0.13) - pane, 0, 1) * inner * (1.0 - duct)
    s.paint(slit, rgb=shade(GROUND, 0.36), rough=0.6, metal=0.3)
    s.paint(pane, rgb=PANE, rough=0.20, metal=0.12, lines=0.0, grain=(0, 0))
    s.level(pane, -1.05, 0.02, relief=False)
    s.edge(pane, 0.035, 0.10, 0.5)

    Fd, Wn = B["field"], B["window"]
    bt = Fd["bite"]
    field = s.rpoly([(Fd["x0"], Fd["y0"], Fd["r"]), (Fd["x1"], Fd["y0"], Fd["r"]), (Fd["x1"], bt["y0"], 0.25), (bt["x"], bt["y1"], 0.25),
                     (bt["x"], Fd["y1"], 1.5), (Fd["x0"], Fd["y1"], 1.6)])
    s.paint(field, rgb=FIELD, rough=0.30, metal=0.45, lines=0.80, grain=(45, 0.85))
    s.paint(np.clip(field - s.grow(field, -0.19), 0, 1), rgb=shade(FIELD, 1.16), lines=0.0)
    # the window: sunk into the field, ring within ring. The shader rules the rings (the window's outline stepped
    # inwards, each ring's corner giving up only `ringTurn` of the step, so they stay round to the middle); the fine
    # grooves' direction written here follows the SAME rings, so the light passes round each corner without a seam
    win = s.rrect(Wn["x0"], Wn["y0"], Wn["x1"], Wn["y1"], Wn["r"])
    s.paint(win, rgb=WINDOW, rough=0.40, metal=0.30, lines=0.72)
    s.level(win, -1.45, 0.30)
    kt = B["ringTurn"]
    ax = np.abs(xx - (Wn["x0"] + Wn["x1"]) / 2) - (Wn["x1"] - Wn["x0"]) / 2 + Wn["r"]
    ay = np.abs(yy - (Wn["y0"] + Wn["y1"]) / 2) - (Wn["y1"] - Wn["y0"]) / 2 + Wn["r"]
    deep = Wn["r"] - np.maximum(ax, ay)                      # how far in a point lies (bridge_body.frag's ringDepth)
    qa, qb, qc = 2 * (1 - kt) ** 2 - kt * kt, 2 * (1 - kt) * (ax + ay) + 2 * Wn["r"] * kt, ax * ax + ay * ay - Wn["r"] ** 2
    turned = (ax + (1 - kt) * deep > 0) & (ay + (1 - kt) * deep > 0)
    deep = np.where(turned, (-qb + np.sqrt(np.maximum(qb * qb - 4 * qa * qc, 0))) / (2 * qa), deep)
    s.grain_along(win, deep, 0.50)
    b = s.box(win, 4)
    for g in (s.gx, s.gy):
        eased = ndimage.gaussian_filter(g[b], 0.25 * s.k)
        g[b] += (eased - g[b]) * win[b]

    E = B["emblem"]
    def epts(pts, turn):
        out = []
        for u, v in pts:
            if turn:
                u, v = 2 * EMBLEM_C[0] - u, 2 * EMBLEM_C[1] - v
            out.append((E["x"] + (u - EMBLEM_C[0]) * E["ux"], E["y"] + (v - EMBLEM_C[1]) * E["uy"]))
        return out
    emblem = np.zeros_like(win)
    for turn in (False, True):
        emblem = np.maximum(emblem, s.poly(epts(EMBLEM_HOOK, turn)))
        emblem = np.maximum(emblem, s.poly(epts(EMBLEM_BLADE, turn)))
    emblem *= win
    s.paint(emblem, rgb=EMBLEM, rough=0.50, metal=0.85, lines=0.0, glow=1.0, grain=(0, 0))
    spark = ndimage.gaussian_filter(s.rng.standard_normal((s.H, s.W)).astype(np.float32), 0.7)     # its metal flake
    s.rgb *= (1.0 + 0.10 * spark * emblem)[:, :, None]

    # the lamp and the macro camera: each in a mirror ring that lies flat under the glass (no edge to catch the light)
    Fl = B["flash"]
    ring = s.circle(Fl["x"], Fl["y"], Fl["ring"])
    s.paint(ring, rgb=[0.50, 0.51, 0.55], rough=0.07, metal=1.0, lines=0.0, grain=(0, 0))
    s.level(ring, -0.36, 0.1, relief=False)
    rim = s.ring(Fl["x"], Fl["y"], Fl["rim"] - 0.42, Fl["rim"])
    s.paint(rim, rgb=CHROME, rough=0.06, metal=1.0)
    s.level(s.circle(Fl["x"], Fl["y"], Fl["rim"]), -0.02, 0.25)      # the one part that stands up to the glass
    lamp = s.circle(Fl["x"], Fl["y"], Fl["lamp"])
    s.paint(lamp, rgb=[0.95, 0.93, 0.84], rough=0.45, metal=0.0)
    s.level(lamp, -0.5, 0.25, relief=False)
    s.grain_round(np.maximum(rim, lamp), Fl["x"], Fl["y"], 0.8)
    for rr in (0.55, 0.85, 1.12):                            # the lens's rings over the diode
        s.paint(s.ring(Fl["x"], Fl["y"], rr - 0.035, rr + 0.035), rgb=[0.80, 0.78, 0.68])
    s.paint(s.circle(Fl["x"], Fl["y"], 0.42), rgb=[0.99, 0.84, 0.36], rough=0.5)
    Mc = B["macro"]
    ring = s.circle(Mc["x"], Mc["y"], Mc["ring"])
    s.paint(ring, rgb=[0.50, 0.51, 0.55], rough=0.07, metal=1.0, lines=0.0, grain=(0, 0))
    s.level(ring, -0.36, 0.1, relief=False)
    glass = s.circle(Mc["x"], Mc["y"], Mc["glass"])
    s.paint(glass, rgb=BLACK, rough=0.05, metal=0.0)
    s.level(glass, -0.55, 0.2, relief=False)
    s.cone(Mc["x"], Mc["y"], Mc["glass"], 1.2, "sink")
    s.paint(s.ring(Mc["x"], Mc["y"], Mc["glass"] * 0.62, Mc["glass"] * 0.72), rgb=[0.10, 0.10, 0.115], rough=0.2)
    s.paint(s.circle(Mc["x"], Mc["y"], Mc["eye"]), rgb=GLASS, rough=0.03)
    s.dome(Mc["x"], Mc["y"], Mc["eye"], 0.2)
    s.paint(s.circle(Mc["x"], Mc["y"], Mc["eye"] * 0.38), rgb=[0.006, 0.006, 0.008])

    # ---- the lined plate ----------------------------------------------------------------------------------------------
    Pl = B["plate"]
    plate = np.clip(inner * (yy > D["y0"]) * (1.0 - duct) * (1.0 - upper), 0, 1)
    s.paint(plate, rgb=PLATE, rough=0.30, metal=0.5, lines=0.5)
    s.level(plate, -0.62, 0.12, relief=False)
    s.paint(plate * (xx < Pl["seam"]), grain=(-45, 0.32))
    s.paint(plate * (xx >= Pl["seam"]), grain=(45, 0.32))

    # what is printed on it: a thin silvery FILM, flat, that the plate's lines show through. Read off the user's
    # close-ups of it line by line (mm): hairlines 0.22 wide; where two run side by side they close into a bar.
    hair = 0.22
    def seg(pts, w=hair):
        return s.line(pts, w)
    yh = -24.9                                               # the head's line
    la, lb = -30.92, -29.76                                  # the left side's pair
    ra, rb_ = 29.98, 30.9                                    # the right side's pair
    yf = 76.26                                               # the foot's line
    art = s.poly([(-29.9, -24.93), (-25.4, -24.93), (-29.9, -20.4)])                                     # the head's corner triangle
    art = np.maximum(art, seg([(ra, yh), (-22.5, yh), (lb, -17.65), (lb, -1.2)]))                        # the head's line, slanting down past the triangle
    art = np.maximum(art, s.poly([(-10.65, yh + hair / 2), (-10.05, yh - 0.6), (20.6, yh - 0.6), (21.2, yh + hair / 2)]))   # ... a band over its middle
    art = np.maximum(art, seg([(la, -16.6), (la, -0.2)]))                                                # down the left: the second hairline,
    art = np.maximum(art, s.poly([(la - hair / 2, -0.3), (lb + hair / 2, -1.45), (lb + hair / 2, 34.4), (la - hair / 2, 35.55)]))   # a bar,
    art = np.maximum(art, seg([(la, 35.3), (la, 54.5)]))                                                 # two hairlines,
    art = np.maximum(art, seg([(lb, 34.3), (lb, 54.5)]))
    art = np.maximum(art, s.poly([(la - hair / 2, 54.3), (lb + hair / 2, 54.3), (lb + hair / 2, 54.6), (la + 0.55, 54.9),
                                  (la + 0.55, 75.7), (-10.2, 75.7), (-10.2, 76.38), (la - hair / 2, 76.38)]))     # and a heavy line down to the foot and along it
    art = np.maximum(art, seg([(-10.4, 76.05), (-7.9, 73.58), (7.2, 73.58), (10.24, yf), (27.64, yf)], 0.28))       # the foot, round the dimmed pill
    art = np.maximum(art, seg([(rb_, -24.63), (rb_, -3.9)]))                                             # down the right: a pair of hairlines from the head's corner,
    art = np.maximum(art, seg([(ra, yh), (ra, -3.0)]))
    art = np.maximum(art, s.poly([(ra - hair / 2, -2.9), (rb_ + hair / 2, -4.05), (rb_ + hair / 2, 44.0), (ra - hair / 2, 45.15)]))  # a bar,
    art = np.maximum(art, seg([(rb_, 43.9), (rb_, 73.0)]))                                               # the pair again,
    art = np.maximum(art, seg([(ra, 45.0), (ra, 72.8)]))
    art = np.maximum(art, s.poly([(ra - hair / 2, 72.66), (rb_ + hair / 2, 72.9), (27.7, yf + 0.14), (26.3, yf + 0.14)]))   # and the foot's slanted corner, filled
    art *= plate
    word = wordmark(s, B["wordmark"]) * plate
    b = s.box(plate)
    fleck = ndimage.gaussian_filter(s.rng.standard_normal(s.rgb[b].shape[:2]).astype(np.float32), 0.8)     # the film's faint shimmer
    fleck /= max(1e-6, float(np.abs(fleck).max()))

    # the mark at the foot: bars of the same film on a patch of the plate that has no lines. The BARS are what lights up.
    M = B["mark"]
    ux, uy = M["w"] / 8.2, M["h"] / 8.95
    def mpts(pts, mirror):
        return [(M["x"] + ((2 * MARK_AXIS - u if mirror else u) - MARK_AXIS) * ux, M["y"] + (v - 4.95) * uy) for u, v in pts]
    bars = np.zeros_like(plate)
    for poly in MARK_BARS:
        for mirror in (False, True):
            bars = np.maximum(bars, s.poly(mpts(poly, mirror)))
    bb = s.box(bars, int(2.5 * s.k))
    shield = np.zeros_like(bars)
    shield[bb] = ndimage.binary_closing(bars[bb] > 0.5, structure=np.ones((int(1.5 * s.k), int(1.5 * s.k)), bool))
    shield = s.soften(s.grow(shield, 0.42), 0.25) * plate
    s.paint(shield, rgb=PLATE, rough=0.36, metal=0.4, lines=0.0, glow=0.0, grain=(0, 0))
    s.paint(bars, glow=1.0)

    # ---- the screws; the film again over the two at the foot (a pill, dimming what is under it); then the mirror
    # border over everything it covers ----------------------------------------------------------------------------------
    for x, y, hidden in B["screws"]:
        screw(s, x, y)
    FP = B["footPill"]
    foot = s.pill(FP["x0"], FP["y0"], FP["x1"], FP["y1"]) * inner
    for m, k in ((art, 0.72), (word, 0.82), (foot, 0.60), (bars, 0.92)):
        s.glaze(m, FILM, k, rough=0.40, metal=0.6, lines=0.62)
    s.rgb[b] *= (1.0 + 0.07 * fleck * np.clip(art + word + foot + bars, 0, 1)[b])[:, :, None]

    border = 1.0 - inner
    s.paint(border, rgb=CHROME, rough=0.035, metal=1.0, lines=0.0, glow=0.0, grain=(0, 0))
    s.level(border, -0.04, 0.02, relief=False)               # a film under the glass: it has no edge to catch the light
    return s


def plateau(sk):
    """A current flagship's back: a one-piece shell of matte anodised aluminium, bare (no glass over it); a camera
    plateau across its head and three lenses on that, which the SHADER raises (BodyGeometry.js `back.plateau`: here they
    are only painted, and shade what lies beside them); a frosted glass panel let into the back below."""
    B = sk["back"]
    base = sk["backBase"]
    s = Canvas(sk["w"], sk["h"])
    s.rgb[:] = np.asarray(base, np.float32)
    s.rough[:] = 0.52
    s.metal[:] = 1.0
    s.bare[:] = 1.0
    b = (slice(None), slice(None))                           # the anodising's fine, even tooth
    tooth = ndimage.gaussian_filter(s.rng.standard_normal((s.H, s.W)).astype(np.float32), 0.6)
    s.rgb *= (1.0 + 0.018 * tooth / max(1e-6, float(np.abs(tooth).max())))[:, :, None]

    T = B["plateau"]
    plat = s.rrect(T["x0"], T["y0"], T["x1"], T["y1"], T["r"])
    s.proud += T["h"] * s.soften(plat, 0.25)
    s.paint(plat, rgb=shade(base, 1.03))

    P = B["panel"]                                           # the glass panel: frosted, the shell's colour a touch paler, a hair's seam round it
    panel = s.rrect(P["x0"], P["y0"], P["x1"], P["y1"], P["r"])
    seam = np.clip(s.grow(panel, 0.10) - panel, 0, 1)
    s.paint(seam, rgb=shade(base, 0.55), rough=0.6, metal=0.3)
    s.paint(panel, rgb=shade(base, 1.07), rough=0.42, metal=0.0)
    s.bare[s.box(panel)] *= 1.0 - panel[s.box(panel)]
    s.level(panel, -0.03, 0.05, relief=False)

    for L in B["lenses"]:                                    # a ring of the shell's metal, polished, round a black pane; the lens deep in it
        x, y, r, rg = L["x"], L["y"], L["r"], L["glass"]
        disc = s.circle(x, y, r)
        s.proud += B["ringH"] * s.soften(disc, 0.15)
        s.paint(disc, rgb=shade(base, 1.10), rough=0.20, metal=1.0)
        s.grain_round(disc, x, y, 0.6)
        pane = s.circle(x, y, rg)
        s.paint(pane, rgb=BLACK, rough=0.05, metal=0.0, grain=(0, 0))
        s.bare[s.box(pane)] *= 1.0 - pane[s.box(pane)]
        s.level(pane, -0.25, 0.12, relief=False)
        barrel = s.circle(x, y, rg * 0.80)
        s.paint(barrel, rgb=[0.011, 0.011, 0.013], rough=0.9)
        s.cone(x, y, rg * 0.80, 2.2, "sink")
        for rr, wd, c in ((0.66, 0.07, [0.085, 0.087, 0.10]), (0.50, 0.08, [0.10, 0.102, 0.116])):
            s.paint(s.ring(x, y, rg * rr - wd, rg * rr + wd), rgb=c, rough=0.22)
        eye = s.circle(x, y, rg * 0.34)
        s.paint(eye, rgb=GLASS, rough=0.03)
        s.dome(x, y, rg * 0.34, 0.18)
        s.paint(s.circle(x, y, rg * 0.13), rgb=[0.006, 0.006, 0.008], rough=0.03)

    Fl, Ld, Mc = B["flash"], B["lidar"], B["mic"]
    lamp = s.circle(Fl["x"], Fl["y"], Fl["r"])               # the lamp: a pale lens over its diodes, a thin metal rim
    s.paint(s.circle(Fl["x"], Fl["y"], Fl["r"] + 0.3), rgb=shade(base, 1.10), rough=0.2, metal=1.0)
    s.paint(lamp, rgb=[0.93, 0.91, 0.82], rough=0.4, metal=0.0)
    s.bare[s.box(lamp)] *= 1.0 - lamp[s.box(lamp)]
    s.level(lamp, -0.15, 0.2, relief=False)
    for rr in (0.45, 0.72):
        s.paint(s.ring(Fl["x"], Fl["y"], Fl["r"] * rr - 0.05, Fl["r"] * rr + 0.05), rgb=[0.80, 0.78, 0.68])
    s.paint(s.circle(Fl["x"], Fl["y"], Fl["r"] * 0.2), rgb=[0.99, 0.86, 0.42], rough=0.5)
    scan = s.circle(Ld["x"], Ld["y"], Ld["r"])               # the depth scanner: a black window
    s.paint(scan, rgb=BLACK, rough=0.06, metal=0.0)
    s.bare[s.box(scan)] *= 1.0 - scan[s.box(scan)]
    s.level(scan, -0.1, 0.1, relief=False)
    hole = s.circle(Mc["x"], Mc["y"], Mc["r"])
    s.paint(hole, rgb=HOLE, rough=0.8, metal=0.0)
    s.level(hole, -0.6, 0.1, relief=False)
    return s


def build(name, sk):
    canvas = redmagic(sk) if sk["back"]["kind"] == "redmagic10s" else plateau(sk)
    out = canvas.back_images()
    out.update(frame_images(sk))
    return out


def preview(images, sk):
    """The back and the four walls side by side, flatly lit: a look at what was drawn (not what the shader makes of it)."""
    a = np.asarray(images["albedo"], np.float32) / 255.0
    n = np.asarray(images["relief"], np.float32)[:, :, :2] / 127.5 - 1.0
    lit = np.clip(a * (0.82 + 0.5 * (-0.55 * n[:, :, 0] - 0.65 * n[:, :, 1]))[:, :, None], 0, 1)
    back = Image.fromarray(Canvas.byte(lit), "RGB")
    fr = images["frame"].rotate(90, expand=True)
    sheet = Image.new("RGB", (back.width + fr.width + 24, max(back.height, fr.height)), (236, 238, 244))
    sheet.paste(back, (0, 0))
    sheet.paste(fr, (back.width + 24, 0))
    return sheet


def main():
    argv = sys.argv[1:]
    check = "--check" in argv
    pdir = argv[argv.index("--preview") + 1] if "--preview" in argv else None
    args = [a for a in argv if not a.startswith("--") and a != pdir]
    table = skins()
    names = args or sorted(table)
    bad = 0
    os.makedirs(OUTDIR, exist_ok=True)
    for name in names:
        if name not in table:
            print("make_decor: no skin named %s" % name, file=sys.stderr)
            return 2
        images = build(name, table[name])
        for kind in KINDS:
            im = images[kind]
            path = os.path.join(OUTDIR, "%s_%s.png" % (name, kind))
            if check:
                same = os.path.exists(path) and np.array_equal(np.asarray(Image.open(path).convert("RGB")), np.asarray(im))
                print("%s  %s" % ("ok  " if same else "STALE", os.path.relpath(path, ROOT)))
                bad += 0 if same else 1
            else:
                im.save(path, optimize=True)
                print("wrote %s  %dx%d  %d KiB" % (os.path.relpath(path, ROOT), im.width, im.height, os.path.getsize(path) // 1024))
        if pdir:
            os.makedirs(pdir, exist_ok=True)
            p = os.path.join(pdir, "%s_preview.png" % name)
            preview(images, table[name]).save(p)
            print("preview %s" % p)
    if check:
        print("MAKE_DECOR RESULT %s" % ("PASS" if bad == 0 else "FAIL (%d stale: run tools/bridge/make_decor.py)" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
