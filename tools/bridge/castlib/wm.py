"""The phone's own screen size and density (`wm size`, `wm density`), and the density a virtual display needs to lay out like it. Pure."""
import re

DPI_MIN, DPI_MAX = 120, 640


def parse_wm(text):
    """The answer of `wm size; wm density` -> (width, height, density), each None when the phone did not say. Override wins over Physical:
    "Physical size: 1216x2688" / "Override size: 1080x2400" / "Physical density: 480" / "Override density: 420"."""
    size, dens = {}, {}
    for line in str(text).splitlines():
        m = re.match(r"\s*(Physical|Override) size:\s*(\d+)x(\d+)", line)
        if m:
            size[m.group(1)] = (int(m.group(2)), int(m.group(3)))
        m = re.match(r"\s*(Physical|Override) density:\s*(\d+)", line)
        if m:
            dens[m.group(1)] = int(m.group(2))
    s = size.get("Override") or size.get("Physical") or (None, None)
    return s[0], s[1], dens.get("Override") or dens.get("Physical")


def dpi_for(width, screen_width, density):
    """The dpi that makes a virtual display `width` px wide lay out like the phone's own screen: density * width / screen_width,
    clamped to [120, 640]. None when the phone's figures are unknown."""
    if not screen_width or not density:
        return None
    return int(min(DPI_MAX, max(DPI_MIN, int(density * width / float(screen_width) + 0.5))))


def parse_new_display(s):
    """`WxH` or `WxH/DPI` -> (width, height, dpi or None); ValueError for anything else."""
    m = re.fullmatch(r"(\d{2,5})x(\d{2,5})(?:/(\d{2,4}))?", str(s).strip())
    if not m:
        raise ValueError("--new-display wants WxH or WxH/DPI")
    return int(m.group(1)), int(m.group(2)), int(m.group(3)) if m.group(3) else None
