#!/usr/bin/env python3
"""pairgen.py -- a theme pair (themes/<name>.json) and its custom btop themes, derived from a small spec of the source palette.

    python3 tools/theme/pairgen.py --list                     the pairs it knows (SPECS, at the bottom)
    python3 tools/theme/pairgen.py <name> [...]               print what it would write (nothing is written)
    python3 tools/theme/pairgen.py --write <name> [...]       write themes/<name>.json and tools/theme/btop/<file> for a custom btop theme
    python3 tools/theme/pairgen.py --write --all              every pair in SPECS
    python3 tools/theme/pairgen.py --report [<name> ...]      the numbers a person checks: contrasts, the distances that keep colours apart
    python3 tools/theme/pairgen.py --logos <line.png> --write the fastfetch logos (tools/theme/fastfetch/archlogo_<name>_<mode>.png): the
                                                          white line logo (~/.config/fastfetch/archlogo_line.png) in each mode's accent

WHY A GENERATOR. A theme file holds ~185 colours per mode, and most of them are not free choices: the carved ladder (sunk, list box,
header, border, shadow, bevel), the button plateau, the note tints, the highlight, the error tint, the starship ramp, the materials of
the network and silicon popups. eva's values ARE the design (CLAUDE.md, "Design language"), so every pair takes eva's relationships and
applies them to its own surface and hues: a ladder step is eva's step in OKLab lightness, with the new surface's hue; a tint is eva's
mix fraction of the new hue over the new surface; an illustration colour (a sun disc, a blueprint's ink) is eva's lightness and chroma
in the new hue. What the source theme says itself (the surface, the text, the accent, the status colours, the hues, the terminal's 16
colours) comes from the SPEC, as faithfully as the shell's rules allow; where a rule forced a deviation the spec says why (`why`).

AFTER IT RAN, THE JSON IS THE THEME. A mockup's Save and a hand edit write the theme file, and a second --write would overwrite them:
re-run it for a new pair, or after changing a spec, not over a pair someone has tuned by hand since.

Gates that read what it makes: tools/dev/bar_hues_table.sh (the bar's glyph hues are distinct in every theme), tools/dev/themectl_cases.py
(every theme renders every target; muted text >= 4.5:1; the group tab and the locked tab stand apart from the border).
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MODES = ("light", "dark")

# ============================================================================================================ colour


def hx(s):
    s = s.strip().lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    return tuple(int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))


def tohex(c):
    return "#" + "".join("%02X" % max(0, min(255, int(math.floor(v * 255 + 0.5)))) for v in c)


def _lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def _gam(v):
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def oklab(c):
    r, g, b = [_lin(x) for x in c]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = [math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s)]
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def _from_oklab(L, a, b):
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)


def lch(c):
    L, a, b = oklab(c)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def from_lch(L, C, h):
    """OKLCh -> sRGB, the chroma reduced until the colour is in gamut (the hue and the lightness are kept)."""
    L = max(0.0, min(1.0, L))

    def mk(c):
        return _from_oklab(L, c * math.cos(math.radians(h)), c * math.sin(math.radians(h)))

    def ok(rgb):
        return all(-1e-5 <= v <= 1 + 1e-5 for v in rgb)
    rgb = mk(C)
    if not ok(rgb):
        lo, hi = 0.0, C
        for _ in range(32):
            mid = (lo + hi) / 2
            if ok(mk(mid)):
                lo = mid
            else:
                hi = mid
        rgb = mk(lo)
    return tuple(_gam(max(0.0, min(1.0, v))) for v in rgb)


def mix(a, b, t):
    """a -> b by t, in OKLab."""
    A, B = oklab(a), oklab(b)
    rgb = _from_oklab(*[A[i] + (B[i] - A[i]) * t for i in range(3)])
    return tuple(_gam(max(0.0, min(1.0, v))) for v in rgb)


def luminance(c):
    r, g, b = [_lin(x) for x in c]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def cielab(c):
    """CIELAB (D65), the one modules/common/glyphs/BarHues.js uses."""
    r, g, b = [_lin(x) for x in c]
    X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(X), f(Y), f(Z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def de2000(c1, c2):
    """CIEDE2000 between two sRGB colours (BarHues.js de2000, the same formula): 2.3 is a just-noticeable step, 15+ another colour."""
    L1, a1, b1 = cielab(c1)
    L2, a2, b2 = cielab(c2)
    rad = math.pi / 180
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = (math.atan2(b1, a1p) / rad + 360) % 360
    h2p = (math.atan2(b2, a2p) / rad + 360) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dh = h2p - h1p
    if C1p * C2p == 0:
        dh = 0
    elif dh > 180:
        dh -= 360
    elif dh < -180:
        dh += 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(dh * rad / 2)
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    if C1p * C2p == 0:
        hbp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hbp = (h1p + h2p) / 2
    elif h1p + h2p < 360:
        hbp = (h1p + h2p + 360) / 2
    else:
        hbp = (h1p + h2p - 360) / 2
    T = (1 - 0.17 * math.cos((hbp - 30) * rad) + 0.24 * math.cos(2 * hbp * rad) + 0.32 * math.cos((3 * hbp + 6) * rad)
         - 0.20 * math.cos((4 * hbp - 63) * rad))
    dth = 30 * math.exp(-(((hbp - 275) / 25) ** 2))
    RC = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    SL = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2)
    SC = 1 + 0.045 * Cbp
    SH = 1 + 0.015 * Cbp * T
    RT = -math.sin(2 * dth * rad) * RC
    return math.sqrt((dLp / SL) ** 2 + (dCp / SC) ** 2 + (dHp / SH) ** 2 + RT * (dCp / SC) * (dHp / SH))


# ======================================================================================================= eva's rules
# Measured on themes/eva.json (OKLab, against its own surface: light #EAEDF5, dark #2C3037), rounded to 4 places.

EVA_SURFACE_C = {"light": 0.0112, "dark": 0.0138}

# token -> (lightness step from the surface, chroma): a neutral of the surface's own hue.
REL = {
    "light": {
        "panelSunk": (-0.0275, 0.0100), "listBox": (-0.0154, 0.0100), "headerBox": (-0.0427, 0.0101), "bevel": (0.0087, 0.0099),
        "border": (-0.0860, 0.0089), "shadowDeep": (-0.1988, 0.0106), "buttonPlateauHover": (0.0208, 0.0099), "ballShadow": (-0.6530, 0.0095),
        "netShell": (-0.1075, 0.0132), "netShellDark": (-0.2315, 0.0156), "netLampOff": (-0.1482, 0.0134), "netBezel": (-0.1616, 0.0139),
        "netShade": (-0.3370, 0.0162), "netGlyphShade": (-0.2970, 0.0160),
        "siliconEvaShadow": (-0.2213, 0.0214), "siliconEvaGroove": (-0.0757, 0.0171), "siliconEvaInk": (-0.3825, 0.0287),
        "siliconEvaSunk": (-0.0576, 0.0157), "siliconEvaWell": (-0.0757, 0.0171), "siliconEvaMetal": (-0.1102, 0.0189),
        "siliconEvaWindow": (-0.6603, 0.0210), "siliconEvaGhost": (-0.5703, 0.0270), "siliconEvaBezel": (-0.2304, 0.0273),
        "siliconEvaGlass": (-0.1117, 0.0197),
        "weatherCloudFront": (0.0477, 0.0029), "weatherCloudBack": (-0.1488, 0.0182), "weatherGlyphShade": (-0.2970, 0.0160),
        "weatherFog": (-0.2385, 0.0237), "weatherFogBar": (-0.2001, 0.0234), "weatherCloud": (-0.3140, 0.0453), "weatherWindLine": (-0.2607, 0.0349),
    },
    "dark": {
        "panelSunk": (-0.0451, 0.0127), "listBox": (-0.0156, 0.0157), "headerBox": (-0.0359, 0.0160), "bevel": (0.0102, 0.0183),
        "border": (-0.0903, 0.0103), "shadowDeep": (-0.1540, 0.0046), "buttonPlateauHover": (0.0198, 0.0136), "buttonBevel": (0.0597, 0.0180),
        "netShell": (0.1187, 0.0178), "netShellDark": (-0.0076, 0.0156), "netLampOff": (0.1406, 0.0176), "netBezel": (0.1622, 0.0173),
        "netRim": (0.4472, 0.0220), "netShade": (-0.1354, 0.0089), "netGlyphShade": (0.3612, 0.0172),
        "siliconEvaBevel": (0.2523, 0.0304), "siliconEvaShadow": (-0.1865, 0.0062), "siliconEvaGroove": (-0.0618, 0.0129),
        "siliconEvaInk": (0.4279, 0.0471), "siliconEvaSunk": (-0.0201, 0.0140), "siliconEvaWell": (-0.0913, 0.0109),
        "siliconEvaMetal": (0.2069, 0.0262), "siliconEvaWindow": (-0.1541, 0.0092), "siliconEvaGhost": (-0.0313, 0.0216),
        "siliconEvaBezel": (0.0669, 0.0274), "siliconEvaGlass": (0.5473, 0.0200),
        "weatherCloudFront": (0.6035, 0.0134), "weatherCloudBack": (0.2959, 0.0300), "weatherGlyphShade": (0.3612, 0.0172),
        "weatherFog": (0.3095, 0.0367), "weatherFogBar": (0.3492, 0.0294), "weatherCloud": (0.4428, 0.0396), "weatherWindLine": (0.4077, 0.0322),
        "hyprBorderInactive": (0.1045, 0.0438),
    },
}

# token -> (eva's OKLab lightness, chroma, the hue it takes in the new pair): an illustration colour, as vivid as eva's, in the pair's hue.
VIVID = {
    "light": {
        "weatherSunDisc": (0.8551, 0.1619, "yellow"), "weatherSunCrown": (0.7525, 0.1653, "orange"), "weatherMoon": (0.7996, 0.1495, "yellow"),
        "weatherStar": (0.8551, 0.1619, "yellow"), "weatherDrop": (0.6487, 0.1680, "blue"), "weatherFlake": (0.7426, 0.1256, "sky"),
        "weatherHail": (0.8161, 0.0820, "sky"), "weatherBolt": (0.8022, 0.1655, "yellow"), "mdMark": (0.9116, 0.0788, "yellow"),
        "siliconBlueprintPaper": (0.9783, 0.0074, "accent"), "siliconBlueprintInk": (0.4477, 0.1499, "accent"),
        "siliconBlueprintFaint": (0.7700, 0.0643, "accent"), "siliconBlueprintGrid": (0.9161, 0.0243, "accent"),
        "siliconBlueprintWash": (0.9440, 0.0166, "accent"), "siliconBlueprintWindow": (0.2642, 0.0771, "accent"),
        "siliconBlueprintGhost": (0.4107, 0.0993, "accent"), "siliconBlueprintBezel": (0.9440, 0.0166, "accent"),
        "siliconBlueprintGlass": (0.8307, 0.0275, "accent"),
    },
    "dark": {
        "weatherSunDisc": (0.8665, 0.1405, "yellow"), "weatherSunCrown": (0.7662, 0.1432, "orange"), "weatherMoon": (0.8184, 0.1263, "yellow"),
        "weatherStar": (0.8790, 0.1234, "yellow"), "weatherDrop": (0.7356, 0.1260, "blue"), "weatherFlake": (0.8316, 0.0863, "sky"),
        "weatherHail": (0.8808, 0.0529, "sky"), "weatherBolt": (0.8159, 0.1436, "yellow"), "mdMark": (0.4388, 0.0438, "yellow"),
        "siliconBlueprintPaper": (0.3618, 0.1034, "accent"), "siliconBlueprintInk": (0.9658, 0.0161, "accent"),
        "siliconBlueprintFaint": (0.7128, 0.0817, "accent"), "siliconBlueprintGrid": (0.4306, 0.1109, "accent"),
        "siliconBlueprintWash": (0.4075, 0.1132, "accent"), "siliconBlueprintWindow": (0.2083, 0.0624, "accent"),
        "siliconBlueprintGhost": (0.3732, 0.1003, "accent"), "siliconBlueprintBezel": (0.4075, 0.1132, "accent"),
        "siliconBlueprintGlass": (0.8437, 0.0330, "accent"),
    },
}

# mix fractions of a hue over the surface (OKLab), fitted on eva
NOTE_T = {"light": 0.175, "dark": 0.155}
ERROR_TINT_T = {"light": 0.12, "dark": 0.19}
TIMER_BREAK_T = {"light": 0.61, "dark": 0.47}
RAMP_T = {"light": (0.19, 0.40, 0.60, 0.84), "dark": (0.20, 0.41, 0.61, 0.82)}
SELECTION_T = {"light": 0.43, "dark": 0.37}
ACCENT_HOVER_T = {"light": 0.106, "dark": 0.12}
ACCENT_BEVEL_T = {"light": 0.35, "dark": 0.39}
NIGHT_T = {"light": 0.26, "dark": 0.49}

# The materials of the network card and the silicon board do not change with the theme (gold is gold): eva's, per mode.
MATERIAL = {
    "light": {"netContact": "#D6A93C", "netPcb": "#2E6B4F", "netTrace": "#C9A227", "netBrass": "#C8A04A", "siliconGold": "#D6A93C",
              "aerialPcb": "#3F6E4A", "aerialShield": "#C9CED6", "aerialSolder": "#B58F6A", "aerialPaper": "#F4F5F7", "aerialGold": "#D6A93C",
              "aerialCoaxMain": "#2B2D33", "aerialCoaxAux": "#8A8F99",
              "aerialChromeSky": "#F3F6FB", "aerialChromeBase": "#D0D6E0", "aerialChromeDeep": "#A9B1BE", "aerialChromeEtch": "#3A3E47",
              "aerialLabelInk": "#2B2D33", "aerialLabelLip": "#FFFFFF",
              "siliconRibbonFilm": "#DBC9A0", "siliconRibbonCopper": "#B58F6A"},
    "dark": {"netContact": "#C79A33", "netPcb": "#1F4A38", "netTrace": "#B08F2A", "netBrass": "#B08C40", "siliconGold": "#C9A227",
             "aerialPcb": "#2C4F36", "aerialShield": "#8F96A3", "aerialSolder": "#8D6F52", "aerialPaper": "#30343C", "aerialGold": "#C9A227",
             "aerialCoaxMain": "#16171B", "aerialCoaxAux": "#6C717C",
             "aerialChromeSky": "#687281", "aerialChromeBase": "#3F444E", "aerialChromeDeep": "#1B1D22", "aerialChromeEtch": "#EDF0F5",
             "aerialLabelInk": "#EEF1F6", "aerialLabelLip": "#0B0C0F",
             "siliconRibbonFilm": "#7D705A", "siliconRibbonCopper": "#B89E80"},
}

WHITE, BLACK = (1.0, 1.0, 1.0), (0.0, 0.0, 0.0)
HUES = ("red", "orange", "yellow", "green", "teal", "sky", "blue", "purple", "pink", "rose", "gray")
ANSI = ("Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White")

# The order of a theme file's keys: themes/everbox.json's, plus hyprGroupTab after hyprBorderLocked.
ORDER = """surface panelSunk listBox headerBox bevel border shadowDeep headerBoxBevel headerBoxShadow textPrimary textMuted textFaint accent
accentHover accentBevel textOnAccent ok warn spill error errorStrong errorTint catCore catExtra catMultilib catAur catFlatpak buttonPlateau
buttonPlateauHover buttonBevel buttonShadow ballShadow shellBorder shellShadow terminalBg terminalFg terminalSelection terminalSelectionText
ansiBlack ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan ansiWhite ansiBrightBlack ansiBrightRed ansiBrightGreen
ansiBrightYellow ansiBrightBlue ansiBrightMagenta ansiBrightCyan ansiBrightWhite llmCode llmSystem llmExplain llmWrite llmData llmOther
weatherSun weatherCloud weatherRain weatherSnow weatherStorm weatherFog weatherNight weatherSunDisc weatherSunCrown weatherMoon weatherStar
weatherCloudFront weatherCloudBack weatherDrop weatherFlake weatherHail weatherBolt weatherFogBar weatherWindLine weatherGlyphShade netShell
netShellDark netContact netLampOff netLampLink netLampAct netLampWarn netPcb netTrace netBrass netBezel netLegend netGlyphShade netRim
netShade batteryCharge batteryDrain batteryLow batteryIdle stockGain stockLoss stockBuy stockSell profileQuiet profileBalanced
profilePerformance profileTweak gpuIntegrated gpuSmart gpuHybrid gpuDgpu siliconEvaSurface siliconEvaBevel siliconEvaShadow
siliconEvaGroove siliconEvaInk siliconEvaSunk siliconEvaWell siliconEvaMetal siliconBlueprintPaper siliconBlueprintInk siliconBlueprintFaint
siliconBlueprintGrid siliconBlueprintWash siliconEvaWindow siliconEvaGhost siliconEvaBezel siliconBlueprintWindow siliconBlueprintGhost
siliconBlueprintBezel siliconEvaGlass siliconBlueprintGlass siliconLock siliconGold siliconMemory siliconRibbonFilm siliconRibbonCopper
siliconEvaLatch siliconBlueprintLatch aerialPcb aerialShield aerialSolder aerialPaper aerialGold aerialCoaxMain aerialCoaxAux aerialChromeSky aerialChromeBase aerialChromeDeep aerialChromeEtch aerialLabelInk aerialLabelLip bandGood bandFair bandModerate bandPoor bandVeryPoor bandExtreme timerRun timerFocus timerBreak
timerCycle2 timerCycle3 timerCycle4 mdRed mdOrange mdYellow mdGreen mdTeal mdBlue mdPurple mdPink mdGray mdMark mdCode noteRed noteOrange
noteYellow noteGreen noteTeal noteBlue notePurple notePink hyprBorderActive hyprBorderInactive hyprBorderLocked hyprGroupTab lockBorder
lockIncorrect starshipRamp0 starshipRamp1 starshipRamp2 starshipRamp3 lockField lockCaps starshipHead starshipOk starshipError""".split()

# Tokens that are the same alias in every pair (eva's own choices)
ALIASES = {
    "headerBoxBevel": "@bevel", "headerBoxShadow": "@shadowDeep", "textOnAccent": "@surface", "buttonPlateau": "@surface",
    "buttonShadow": "@shadowDeep", "shellShadow": "@ballShadow", "terminalBg": "@panelSunk", "terminalFg": "@textPrimary",
    "terminalSelectionText": "@textPrimary", "netLampLink": "@ok", "netLampAct": "@accent", "netLampWarn": "@warn", "netLegend": "@textFaint",
    "batteryCharge": "@ok", "batteryDrain": "@spill", "batteryLow": "@error", "batteryIdle": "@accent", "stockGain": "@ok",
    "stockLoss": "@error", "stockBuy": "@accent", "stockSell": "@warn", "profileQuiet": "@ok", "profileBalanced": "@accent",
    "profilePerformance": "@warn", "profileTweak": "@catFlatpak", "gpuIntegrated": "@ok", "gpuSmart": "@catMultilib", "gpuHybrid": "@accent",
    "gpuDgpu": "@warn", "siliconEvaSurface": "@surface", "siliconLock": "@warn", "siliconEvaLatch": "@siliconEvaWindow",
    "siliconBlueprintLatch": "@siliconBlueprintWindow", "bandGood": "@catMultilib", "bandFair": "@ok", "bandModerate": "@spill",
    "bandPoor": "@warn", "bandVeryPoor": "@error", "bandExtreme": "@catFlatpak", "timerRun": "@catMultilib", "timerFocus": "@warn",
    "timerCycle2": "@catFlatpak", "timerCycle3": "@spill", "timerCycle4": "@catExtra", "mdCode": "@headerBox", "hyprBorderActive": "@accent",
    "lockBorder": "@hyprBorderInactive", "lockField": "@panelSunk", "lockCaps": "@warn", "starshipHead": "@accent", "starshipOk": "@ok",
    "starshipError": "@error", "hyprGroupTab": "@warn",
}


def _rel(mode, tok, surface):
    """eva's neutral at the same step from the new surface, in the surface's hue. Its chroma follows the surface's (a navy ground has navy
    shadows) only near the surface: a step far from it (a cloud, a board's ink) keeps eva's own chroma, or a tinted ground would paint its
    clouds and inks in a saturated version of itself."""
    dL, C = REL[mode][tok]
    L0, C0, h0 = lch(surface)
    if C0 < 0.004:                                   # a grey surface: its neutrals are grey too (a grey has no hue to keep)
        return from_lch(L0 + dL, 0.0, 0.0)
    k = max(0.4, min(3.0, C0 / EVA_SURFACE_C[mode]))
    k = 1 + (k - 1) * max(0.0, 1 - abs(dL) / 0.25)
    return from_lch(L0 + dL, C * k, h0)


def _vivid(mode, tok, hue_of):
    L, C, src = VIVID[mode][tok]
    return from_lch(L, C, lch(hue_of(src))[2])


def build_mode(name, mode, m):
    """The resolved colours (hex) and aliases of one mode, from its spec block m."""
    c = {k: hx(v) for k, v in m.items() if isinstance(v, str) and v.startswith("#")}
    hues = {k: hx(v) for k, v in m["hues"].items()}
    S = c["surface"]

    def hue(h):
        if h == "accent":
            return c["accent"]
        if h in hues:
            return hues[h]
        raise SystemExit("pairgen: %s %s: no hue %s" % (name, mode, h))
    out = {}
    put = out.__setitem__
    for k in ("surface", "textPrimary", "textMuted", "textFaint", "accent", "ok", "warn", "spill", "error"):
        put(k, c[k])
    for k in REL[mode]:
        put(k, _rel(mode, k, S))
    if mode == "light":
        put("buttonBevel", WHITE)
        put("netRim", WHITE)
        put("siliconEvaBevel", WHITE)
        put("hyprBorderInactive", "@border")
        put("shellBorder", "@border")
        put("lockIncorrect", "@error")
    else:
        put("ballShadow", BLACK)
        put("shellBorder", "@buttonBevel")
        put("lockIncorrect", "@errorStrong")
    put("accentHover", mix(c["accent"], WHITE, ACCENT_HOVER_T[mode]))
    put("accentBevel", mix(c["accent"], WHITE, ACCENT_BEVEL_T[mode]))
    if "errorStrong" in c:
        put("errorStrong", c["errorStrong"])
    elif mode == "light":
        put("errorStrong", mix(c["error"], WHITE, 0.25))
    else:
        L, C, h = lch(c["error"])
        put("errorStrong", from_lch(L - 0.06, C * 1.15, h))
    put("errorTint", mix(S, c["error"], ERROR_TINT_T[mode]))
    for cat, h in (("catCore", "orange"), ("catExtra", "green"), ("catMultilib", "teal"), ("catAur", "blue"), ("catFlatpak", "purple")):
        put(cat, hue(m.get("cat", {}).get(cat, h)))
    put("terminalSelection", c.get("terminalSelection") or mix(S, c["accent"], SELECTION_T[mode]))
    for i, a in enumerate(ANSI):
        put("ansi" + a, hx(m["ansi"][i]))
        put("ansiBright" + a, hx(m["ansi"][8 + i]))
    for k, h in (("llmCode", "purple"), ("llmSystem", "orange"), ("llmExplain", "green"), ("llmWrite", "pink"), ("llmData", "sky"),
                 ("llmOther", "rose"), ("weatherSun", "yellow"), ("weatherRain", "blue"), ("weatherSnow", "sky"), ("weatherStorm", "purple"),
                 ("siliconMemory", "pink"), ("mdRed", "red"), ("mdOrange", "orange"), ("mdYellow", "yellow"), ("mdGreen", "green"),
                 ("mdTeal", "teal"), ("mdBlue", "blue"), ("mdPurple", "purple"), ("mdPink", "pink"), ("mdGray", "gray")):
        put(k, hue(h))
    put("weatherNight", mix(hue("blue"), hue("purple"), NIGHT_T[mode]))
    for k in VIVID[mode]:
        put(k, _vivid(mode, k, hue))
    for k, v in MATERIAL[mode].items():
        put(k, hx(v))
    put("timerBreak", mix(S, hue("orange"), TIMER_BREAK_T[mode]))
    for k, h in (("noteRed", "red"), ("noteOrange", "orange"), ("noteYellow", "yellow"), ("noteGreen", "green"), ("noteTeal", "teal"),
                 ("noteBlue", "blue"), ("notePurple", "purple"), ("notePink", "pink")):
        put(k, mix(S, hue(h), NOTE_T[mode]))
    for i, t in enumerate(RAMP_T[mode]):
        put("starshipRamp%d" % i, mix(S, c["accent"], t))
    put("hyprBorderLocked", hue(m["locked"]) if not m["locked"].startswith("#") else hx(m["locked"]))
    for k, v in ALIASES.items():
        out.setdefault(k, v)
    for k, v in m.get("set", {}).items():                          # a spec's own last word on a token (its `why` says why)
        out[k] = v if v.startswith("@") else hx(v)
    missing = [k for k in ORDER if k not in out]
    extra = [k for k in out if k not in ORDER]
    if missing or extra:
        raise SystemExit("pairgen: %s %s: missing %s, unknown %s" % (name, mode, missing, extra))
    return {k: (out[k] if isinstance(out[k], str) else tohex(out[k])) for k in ORDER}


def resolved(block):
    """{token: (r, g, b)} with every alias followed (themectl's resolver does the same; recipes are not used here)."""
    out = {}

    def get(k, seen=()):
        v = block[k]
        if v.startswith("@"):
            if k in seen:
                raise SystemExit("pairgen: alias cycle at %s" % k)
            return get(v[1:], seen + (k,))
        return hx(v)
    for k in block:
        out[k] = get(k)
    return out


def build(name, spec):
    doc = {"name": name, "note": spec["note"]}
    for mode in MODES:
        doc[mode] = build_mode(name, mode, spec[mode])
    doc["assets"] = {mode: spec[mode]["assets"] for mode in MODES}
    return doc


# ================================================================================================= btop, logos


BTOP_KEYS = ["main_bg", "main_fg", "title", "hi_fg", "selected_bg", "selected_fg", "inactive_fg", "graph_text", "meter_bg", "proc_misc",
             "cpu_box", "mem_box", "net_box", "proc_box", "div_line", "temp_start", "temp_mid", "temp_end", "cpu_start", "cpu_mid", "cpu_end",
             "free_start", "free_mid", "free_end", "cached_start", "cached_mid", "cached_end", "available_start", "available_mid",
             "available_end", "used_start", "used_mid", "used_end", "download_start", "download_mid", "download_end", "upload_start",
             "upload_mid", "upload_end", "process_start", "process_mid", "process_end"]

# btop's roles in hue words (the structure of catppuccin's own btop themes: cool CPU, warm net down, green memory used): a spec's `btop`
# block overrides any of them with a hue word, a token name or "#RRGGBB"; "" leaves a gradient's middle empty.
BTOP_ROLES = {
    "main_bg": "surface", "main_fg": "textPrimary", "title": "textPrimary", "hi_fg": "accent", "selected_bg": "@selected",
    "selected_fg": "accent", "inactive_fg": "textFaint", "graph_text": "textMuted", "meter_bg": "@meter", "proc_misc": "accent",
    "cpu_box": "purple", "mem_box": "green", "net_box": "red", "proc_box": "blue", "div_line": "@divider",
    "temp_start": "green", "temp_mid": "yellow", "temp_end": "red", "cpu_start": "teal", "cpu_mid": "sky", "cpu_end": "purple",
    "free_start": "purple", "free_mid": "", "free_end": "blue", "cached_start": "sky", "cached_mid": "", "cached_end": "blue",
    "available_start": "orange", "available_mid": "", "available_end": "red", "used_start": "green", "used_mid": "", "used_end": "teal",
    "download_start": "orange", "download_mid": "", "download_end": "red", "upload_start": "green", "upload_mid": "", "upload_end": "teal",
    "process_start": "sky", "process_mid": "", "process_end": "purple",
}


def btop_theme(name, mode, spec, block):
    m = spec[mode]
    col = resolved(block)
    hues = {k: hx(v) for k, v in m["hues"].items()}
    S = col["surface"]
    special = {"@selected": mix(S, col["accent"], 0.22 if mode == "light" else 0.28), "@meter": col["border"] if mode == "light" else _rel(mode, "netShell", S),
               "@divider": mix(S, col["textFaint"], 0.6)}
    roles = dict(BTOP_ROLES, **m.get("btop", {}))
    lines = ["# %s %s -- a btop theme made by tools/theme/pairgen.py from themes/%s.json (%s), for the btop target of tools/theme/themectl." % (spec["title"], mode, name, mode),
             "# themectl copies it into ~/.config/btop/themes/ when first used (and `themectl install` refreshes it) and points current.theme",
             "# at it. Edit freely: a copy there that is newer than the repo's is kept. Colours are \"#RRGGBB\"; an empty value is btop's default.",
             ""]
    for k in BTOP_KEYS:
        r = roles[k]
        if r == "":
            v = ""
        elif r.startswith("#"):
            v = r.upper()
        elif r in special:
            v = tohex(special[r])
        elif r in hues:
            v = tohex(hues[r])
        elif r in col:
            v = tohex(col[r])
        else:
            raise SystemExit("pairgen: %s %s btop role %s=%s is not a hue, a token or a colour" % (name, mode, k, r))
        lines.append('theme[%s]="%s"' % (k, v))
    return "\n".join(lines) + "\n"


def write_logo(line_png, accent_hex, out):
    """The line logo's coverage in one colour: an indexed PNG whose index IS the alpha (every entry the accent, tRNS 0..255), a third of
    the bytes of RGBA. Half the user's 2731 px: fastfetch draws it 48 cells wide."""
    from PIL import Image
    alpha = Image.open(line_png).convert("RGBA").getchannel("A").resize((1366, 1366), Image.LANCZOS)
    r, g, b = [int(math.floor(v * 255 + 0.5)) for v in hx(accent_hex)]
    im = Image.frombytes("P", alpha.size, alpha.tobytes())
    im.putpalette([r, g, b] * 256)
    im.save(out, optimize=True, transparency=bytes(range(256)))


# ============================================================================================================ report


def report(name, doc):
    rows = []
    for mode in MODES:
        col = resolved(doc[mode])
        S = col["surface"]
        rows.append("%s %s  surface %s" % (name, mode, doc[mode]["surface"]))
        for k in ("textPrimary", "textMuted", "textFaint", "accent", "ok", "warn", "spill", "error"):
            rows.append("    %-12s %s  contrast on surface %.2f" % (k, tohex(col[k]), contrast(col[k], S)))
        rows.append("    textOnAccent on accent %.2f" % contrast(col["textOnAccent"], col["accent"]))
        for a, b in (("accent", "error"), ("accent", "warn"), ("accent", "ok"), ("warn", "error"), ("warn", "spill"), ("ok", "accent"),
                     ("hyprGroupTab", "hyprBorderActive"), ("hyprBorderLocked", "hyprBorderActive"), ("hyprBorderLocked", "hyprGroupTab"),
                     ("hyprGroupTab", "hyprBorderInactive"), ("batteryIdle", "batteryDrain")):
            rows.append("    %-17s vs %-17s CIEDE2000 %5.1f" % (a, b, de2000(col[a], col[b])))
    return "\n".join(rows)


# ============================================================================================================== main


def main(argv=None):
    ap = argparse.ArgumentParser(description="theme pairs from source palettes (see the header)")
    ap.add_argument("names", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--logos", metavar="LINE_PNG")
    a = ap.parse_args(argv)
    if a.list:
        for n in sorted(SPECS):
            print(n)
        return 0
    names = sorted(SPECS) if a.all or (a.report and not a.names) else a.names
    unknown = [n for n in names if n not in SPECS]
    if unknown or not names:
        print("pairgen: name a pair (have: %s)" % ", ".join(sorted(SPECS)))
        return 2
    for n in names:
        spec = SPECS[n]
        doc = build(n, spec)
        if a.report:
            print(report(n, doc))
            continue
        text = json.dumps(doc, indent=4, ensure_ascii=False) + "\n"
        btops = {}
        for mode in MODES:
            f = spec[mode]["assets"]["btopTheme"]
            if "/" not in f:
                btops[f] = btop_theme(n, mode, spec, doc[mode])
        if a.write:
            with open(os.path.join(REPO, "themes", n + ".json"), "w", encoding="utf-8") as fh:
                fh.write(text)
            os.makedirs(os.path.join(HERE, "btop"), exist_ok=True)
            for f, t in btops.items():
                with open(os.path.join(HERE, "btop", f), "w", encoding="utf-8") as fh:
                    fh.write(t)
            if a.logos:
                os.makedirs(os.path.join(HERE, "fastfetch"), exist_ok=True)
                for mode in MODES:
                    write_logo(a.logos, doc[mode]["accent"], os.path.join(HERE, "fastfetch", spec[mode]["assets"]["fastfetchLogo"]))
            print("wrote themes/%s.json%s" % (n, "".join(", tools/theme/btop/" + f for f in btops)))
        else:
            sys.stdout.write(text)
            for f, t in btops.items():
                sys.stdout.write("---- tools/theme/btop/%s\n%s" % (f, t))
    return 0


# ============================================================================================================= specs
# One block per mode:
#   surface textPrimary textMuted textFaint accent ok warn spill error [errorStrong] [terminalSelection]   the source's own colours
#   hues      red orange yellow green teal sky blue purple pink rose gray: what the modules draw in (llm, weather, md, notes, categories)
#   ansi      the 16 terminal colours, color0..color15 (kitty's order), as the source's terminal has them
#   locked    the hue (or "#hex") of a locked group's tab: apart from the border (the accent) and the group tab (warn)
#   cat       optional {catX: hue} where yay's repo colours would land on the accent
#   btop      optional {role: hue | token | "#hex"} over BTOP_ROLES
#   set       optional {token: "#hex" | "@alias"}: the last word, each one explained in the pair's note
#   assets    gtkTheme iconTheme fastfetchLogo btopTheme vscodeTheme (gtkTheme, iconTheme and vscodeTheme may be a list, best first: themectl takes the first installed, else the last; btopTheme: an absolute stock path, or a bare file name this script
#             writes into tools/theme/btop/)

SPECS = {}

SPECS["monokai"] = {
    "title": "Monokai",
    "note": "Monokai Pro (VS Code: 'Monokai Pro Light' / 'Monokai Pro', monokai.theme-monokai-pro-vscode 2.0.16). Surfaces, text and the six hues are the "
            "VS Code themes' own; the terminal is their integrated terminal's palette, where blue IS the orange (Monokai Pro has no blue). The accent is "
            "the cyan in both modes: the source's UI accent is yellow in dark (the shell's spill/drain colour) and the error pink in light, either of "
            "which would make a state unreadable. Teal, blue and pink are not in the palette: mixes of its neighbours. The terminal's bright blue "
            "(color12), which the source fills with the orange once more, is a blue: the bar's Bluetooth and LLM glyphs need one apart from the "
            "cyan and the purple. Group tabs: the tab is the orange (warn), a locked group's tab the purple. btop: custom (btop's own monokai is "
            "the classic Monokai on #060604, not the Pro; the files are monokai-light and monokai-dark, apart from btop's monokai.theme). "
            "The pair was monokai-pro until 2026-11-08 (themectl install renames it in your home).",
    "light": {
        "surface": "#FAF4F2", "textPrimary": "#29242A", "textMuted": "#706B6E", "textFaint": "#918C8E",
        "accent": "#1C8CA8", "ok": "#269D69", "warn": "#E16032", "spill": "#CC7A0A", "error": "#E14775", "errorStrong": "#C9305E",
        "terminalSelection": "#E0D9D7",
        "hues": {"red": "#E14775", "orange": "#E16032", "yellow": "#CC7A0A", "green": "#269D69", "teal": "#2A9A8C", "sky": "#1C8CA8",
                 "blue": "#4E7FE0", "purple": "#7058BE", "pink": "#B94D9E", "rose": "#D96A7E", "gray": "#918C8E"},
        "ansi": ["#D3CDCC", "#E14775", "#269D69", "#CC7A0A", "#E16032", "#7058BE", "#1C8CA8", "#29242A",
                 "#A59FA0", "#E14775", "#269D69", "#CC7A0A", "#4E7FE0", "#7058BE", "#1C8CA8", "#29242A"],
        "locked": "purple",
        "cat": {"catAur": "blue"},
        "assets": {"gtkTheme": ["Colloid-Teal-Light", "XFCE_Colour_Lite_Beryl"], "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_monokai_light.png",
                   "btopTheme": "monokai-light.theme", "vscodeTheme": "Monokai Pro Light"},
    },
    "dark": {
        "surface": "#2D2A2E", "textPrimary": "#FCFCFA", "textMuted": "#C1C0C0", "textFaint": "#727072",
        "accent": "#78DCE8", "ok": "#A9DC76", "warn": "#FC9867", "spill": "#FFD866", "error": "#FF6188", "errorStrong": "#F0446F",
        "terminalSelection": "#5B595C",
        "hues": {"red": "#FF6188", "orange": "#FC9867", "yellow": "#FFD866", "green": "#A9DC76", "teal": "#8FDCB0", "sky": "#78DCE8",
                 "blue": "#6E9CF7", "purple": "#AB9DF2", "pink": "#E88AC6", "rose": "#FF8FA6", "gray": "#939293"},
        "ansi": ["#403E41", "#FF6188", "#A9DC76", "#FFD866", "#FC9867", "#AB9DF2", "#78DCE8", "#FCFCFA",
                 "#727072", "#FF6188", "#A9DC76", "#FFD866", "#4F86F2", "#AB9DF2", "#78DCE8", "#FCFCFA"],
        "locked": "purple",
        "cat": {"catAur": "blue"},
        "assets": {"gtkTheme": ["Colloid-Teal-Dark", "XFCE_Colour_Dark_Beryl"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_monokai_dark.png",
                   "btopTheme": "monokai-dark.theme", "vscodeTheme": "Monokai Pro"},
    },
}

SPECS["tokyo-night"] = {
    "title": "Tokyo Night",
    "note": "Tokyo Night (VS Code enkia.tokyo-night 1.1.2): dark is 'Tokyo Night Storm', light is 'Tokyo Night Light' (the extension's one light theme, "
            "the 'regular' light). Light takes the VS Code theme's own deep, muted palette, its terminal included. Dark takes Storm's surface and "
            "the Tokyo Night palette as kitty ships it (folke's tokyonight_storm: green #9ECE6A, where the VS Code terminal has the teal #73DACA "
            "for green beside a cyan, two colours a glyph could not tell apart). Departures, each for a rule of the shell: the muted text is a greyer "
            "ink than the source's blue-grey (#5E606C / #A9AEC0), which sat within a glyph's distance of the blue and the magenta, so an off glyph "
            "read as on; dark's bright cyan (color14) is the teal #73DACA and its faint text #5F6894 (2.7:1; the comment colour is 2.35:1); "
            "light's spill and bright yellow (color11) are the ochre #9A7A2C, apart from the orange. Group tabs: the tab is the orange, a locked "
            "group's tab the teal. btop: the stock tokyo-storm in dark, custom in light.",
    "light": {
        "surface": "#E6E7ED", "textPrimary": "#343B58", "textMuted": "#5E606C", "textFaint": "#8990A3",
        "accent": "#2959AA", "ok": "#385F0D", "warn": "#965027", "spill": "#9A7A2C", "error": "#BD4040", "errorStrong": "#942F2F",
        "terminalSelection": "#C4C8DA",
        "hues": {"red": "#8C4351", "orange": "#965027", "yellow": "#8F5E15", "green": "#385F0D", "teal": "#33635C", "sky": "#006C86",
                 "blue": "#2959AA", "purple": "#65359D", "pink": "#7B43BA", "rose": "#A85868", "gray": "#707280"},
        "ansi": ["#343B58", "#8C4351", "#33635C", "#8F5E15", "#2959AA", "#7B43BA", "#006C86", "#707280",
                 "#343B58", "#8C4351", "#33635C", "#9A7A2C", "#2959AA", "#7B43BA", "#006C86", "#707280"],
        "locked": "teal",
        "assets": {"gtkTheme": ["Tokyonight-Light", "XFCE_Colour_Lite_Doder"], "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_tokyo-night_light.png",
                   "btopTheme": "tokyo-night-light.theme", "vscodeTheme": "Tokyo Night Light"},
    },
    "dark": {
        "surface": "#24283B", "textPrimary": "#C0CAF5", "textMuted": "#A9AEC0", "textFaint": "#5F6894",
        "accent": "#7AA2F7", "ok": "#9ECE6A", "warn": "#FF9E64", "spill": "#E0AF68", "error": "#F7768E", "errorStrong": "#DB4B4B",
        "terminalSelection": "#2E3C64",
        "hues": {"red": "#F7768E", "orange": "#FF9E64", "yellow": "#E0AF68", "green": "#9ECE6A", "teal": "#73DACA", "sky": "#7DCFFF",
                 "blue": "#7AA2F7", "purple": "#BB9AF7", "pink": "#E68AC6", "rose": "#FF899D", "gray": "#737AA2"},
        "ansi": ["#1D202F", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                 "#414868", "#FF899D", "#9FE044", "#FABA4A", "#8DB0FF", "#C7A9FF", "#73DACA", "#C0CAF5"],
        "locked": "teal",
        "assets": {"gtkTheme": ["catppuccin-macchiato-blue-standard+default", "Tokyonight-Dark", "XFCE_Colour_Dark_Doder"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_tokyo-night_dark.png",
                   "btopTheme": "/usr/share/btop/themes/tokyo-storm.theme", "vscodeTheme": "Tokyo Night Storm"},
    },
}

SPECS["catppuccin"] = {
    "title": "Catppuccin",
    "note": "Catppuccin (VS Code catppuccin.catppuccin-vsc 3.19.0): light is Latte, dark is Macchiato, in the official palettes; the accent is mauve, the "
            "extension's own default. Surfaces: base; muted text: subtext0; faint: overlay1 (Latte) / overlay0 (Macchiato). The terminal is the "
            "extension's integrated palette (the official kitty themes'). Departures: Latte's muted text is #676A81, between subtext0 (4.37:1 on base, "
            "under the shell's 4.5) and subtext1; Macchiato's bright blue (color12) is #5E8CF5, apart from the blue-grey subtext0 the off glyphs "
            "wear. Group tabs: the tab is peach, a locked group's tab sky. btop has no stock Catppuccin: custom, in the structure of "
            "Catppuccin's own btop themes.",
    "light": {
        "surface": "#EFF1F5", "textPrimary": "#4C4F69", "textMuted": "#676A81", "textFaint": "#8C8FA1",
        "accent": "#8839EF", "ok": "#40A02B", "warn": "#FE640B", "spill": "#DF8E1D", "error": "#D20F39", "errorStrong": "#E64553",
        "terminalSelection": "#ACB0BE",
        "hues": {"red": "#D20F39", "orange": "#FE640B", "yellow": "#DF8E1D", "green": "#40A02B", "teal": "#179299", "sky": "#04A5E5",
                 "blue": "#1E66F5", "purple": "#8839EF", "pink": "#EA76CB", "rose": "#DD7878", "gray": "#7C7F93"},
        "ansi": ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                 "#6C6F85", "#DE293E", "#49AF3D", "#EEA02D", "#456EFF", "#FE85D8", "#2D9FA8", "#BCC0CC"],
        "locked": "sky",
        "btop": {"proc_misc": "#DC8A78", "graph_text": "#DC8A78", "net_box": "#E64553", "cpu_end": "#7287FD", "free_mid": "#7287FD",
                 "cached_mid": "#1E66F5", "cached_end": "#7287FD", "available_mid": "#E64553", "used_mid": "teal", "used_end": "sky",
                 "download_mid": "#E64553", "upload_mid": "teal", "upload_end": "sky", "process_mid": "#7287FD"},
        "assets": {"gtkTheme": ["catppuccin-latte-mauve-standard+default", "XFCE_Colour_Lite_Purple"], "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_catppuccin_light.png",
                   "btopTheme": "catppuccin-latte.theme", "vscodeTheme": "Catppuccin Latte"},
    },
    "dark": {
        "surface": "#24273A", "textPrimary": "#CAD3F5", "textMuted": "#A5ADCB", "textFaint": "#6E738D",
        "accent": "#C6A0F6", "ok": "#A6DA95", "warn": "#F5A97F", "spill": "#EED49F", "error": "#ED8796", "errorStrong": "#EE99A0",
        "terminalSelection": "#5B6078",
        "hues": {"red": "#ED8796", "orange": "#F5A97F", "yellow": "#EED49F", "green": "#A6DA95", "teal": "#8BD5CA", "sky": "#91D7E3",
                 "blue": "#8AADF4", "purple": "#C6A0F6", "pink": "#F5BDE6", "rose": "#F0C6C6", "gray": "#939AB7"},
        "ansi": ["#494D64", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB",
                 "#5B6078", "#EC7486", "#8CCF7F", "#E1C682", "#5E8CF5", "#F2A9DD", "#63CBC0", "#B8C0E0"],
        "locked": "sky",
        "btop": {"proc_misc": "#F4DBD6", "graph_text": "#F4DBD6", "net_box": "#EE99A0", "cpu_end": "#B7BDF8", "free_mid": "#B7BDF8",
                 "cached_mid": "#8AADF4", "cached_end": "#B7BDF8", "available_mid": "#EE99A0", "used_mid": "teal", "used_end": "sky",
                 "download_mid": "#EE99A0", "upload_mid": "teal", "upload_end": "sky", "process_mid": "#B7BDF8"},
        "assets": {"gtkTheme": ["catppuccin-macchiato-mauve-standard+default", "XFCE_Colour_Dark_Purple"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_catppuccin_dark.png",
                   "btopTheme": "catppuccin-macchiato.theme", "vscodeTheme": "Catppuccin Macchiato"},
    },
}

SPECS["night-owl"] = {
    "title": "Night Owl",
    "note": "Night Owl (VS Code sdras.night-owl 2.1.1): dark is 'Night Owl', light is 'Night Owl Light' (Light Owl). Dark keeps the deep #011627; light's "
            "surface is its UI chrome #F0F0F0 (the editor's #FBFBFB leaves the bevel no room above it). The accent is Night Owl's blue, the colour "
            "both variants use most; the terminal is the VS Code themes' integrated palette. Light Owl has no orange: warn is the mix of its red "
            "and its yellow. Departures: Light Owl's bright green (color10) is #4D9A2B (its green and cyan were too close for the power reel) and "
            "its faint text #8496A0 (2.7:1); Night Owl's muted text is a greyer #9AA3AD than the sidebar's #89A4BB, which sat beside its blue. "
            "Group tabs: the tab is the orange, a locked group's tab the teal. btop: the stock night-owl in dark, custom in light.",
    "light": {
        "surface": "#F0F0F0", "textPrimary": "#403F53", "textMuted": "#5F6075", "textFaint": "#8496A0",
        "accent": "#4876D6", "ok": "#08916A", "warn": "#E0752A", "spill": "#C99A00", "error": "#DE3D3B", "errorStrong": "#BC2F2D",
        "terminalSelection": "#D3E8F8",
        "hues": {"red": "#DE3D3B", "orange": "#E0752A", "yellow": "#DAAA01", "green": "#08916A", "teal": "#2AA298", "sky": "#0C969B",
                 "blue": "#4876D6", "purple": "#994CC3", "pink": "#D6438A", "rose": "#C96765", "gray": "#989FB1"},
        "ansi": ["#403F53", "#DE3D3B", "#08916A", "#E0AF02", "#288ED7", "#D6438A", "#2AA298", "#93A1A1",
                 "#403F53", "#DE3D3B", "#4D9A2B", "#DAAA01", "#288ED7", "#D6438A", "#2AA298", "#93A1A1"],
        "locked": "teal",
        "assets": {"gtkTheme": ["adw-gtk3", "Colloid-Light", "Tokyonight-Light", "XFCE_Colour_Lite_Doder"], "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_night-owl_light.png",
                   "btopTheme": "night-owl-light.theme", "vscodeTheme": "Night Owl Light"},
    },
    "dark": {
        "surface": "#011627", "textPrimary": "#D6DEEB", "textMuted": "#9AA3AD", "textFaint": "#5F7E97",
        "accent": "#82AAFF", "ok": "#22DA6E", "warn": "#F78C6C", "spill": "#ECC48D", "error": "#EF5350", "errorStrong": "#FF5874",
        "terminalSelection": "#1D3B53",
        "hues": {"red": "#EF5350", "orange": "#F78C6C", "yellow": "#FFEB95", "green": "#ADDB67", "teal": "#7FDBCA", "sky": "#21C7A8",
                 "blue": "#82AAFF", "purple": "#C792EA", "pink": "#FF5874", "rose": "#FF869A", "gray": "#637777"},
        "ansi": ["#011627", "#EF5350", "#22DA6E", "#C5E478", "#82AAFF", "#C792EA", "#21C7A8", "#FFFFFF",
                 "#575656", "#EF5350", "#22DA6E", "#FFEB95", "#82AAFF", "#C792EA", "#7FDBCA", "#FFFFFF"],
        "locked": "teal",
        "assets": {"gtkTheme": ["catppuccin-macchiato-blue-standard+default", "Colloid-Dark", "Tokyonight-Dark", "XFCE_Colour_Dark_Doder"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_night-owl_dark.png",
                   "btopTheme": "/usr/share/btop/themes/night-owl.theme", "vscodeTheme": "Night Owl"},
    },
}

SPECS["paper"] = {
    "title": "Paper",
    "note": "Paper: btop's paper theme and the vim-paper palette it comes from (yorickpeterse/vim-paper: #F2EEDE, black ink, red #CC3E28, green "
            "#216609, blue #1E6FCC, yellow #B58900, purple #5C21A5, cyan #158C86, orange #A55000, the greys). Light is that palette as it is; its "
            "terminal is vim-paper's own sixteen. Dark is made here and keeps the character: the same warm paper hue, now the ground at low "
            "lightness, the paper colour as the ink, and the same sparse hues raised just enough to read on it. btop: the stock paper in light, "
            "custom in dark (monochrome boxes, as paper's are). Group tabs: the tab is the orange, a locked group's tab purple (light) / teal "
            "(dark). VS Code: the Paper extension (a5hk.paper) in light when it is installed, else Quiet Light; Kimbie Dark in dark.",
    "light": {
        "surface": "#F2EEDE", "textPrimary": "#000000", "textMuted": "#555555", "textFaint": "#777777",
        "accent": "#1E6FCC", "ok": "#216609", "warn": "#A55000", "spill": "#B58900", "error": "#CC3E28", "errorStrong": "#E06450",
        "terminalSelection": "#D8D5C7",
        "hues": {"red": "#CC3E28", "orange": "#A55000", "yellow": "#B58900", "green": "#216609", "teal": "#158C86", "sky": "#2A8FB8",
                 "blue": "#1E6FCC", "purple": "#5C21A5", "pink": "#9C2F7A", "rose": "#B8564A", "gray": "#777777"},
        "ansi": ["#000000", "#CC3E28", "#216609", "#B58900", "#1E6FCC", "#5C21A5", "#158C86", "#AAAAAA",
                 "#555555", "#CC3E28", "#216609", "#B58900", "#1E6FCC", "#5C21A5", "#158C86", "#AAAAAA"],
        "locked": "purple",
        "set": {"mdMark": "#F2DE91"},
        "assets": {"gtkTheme": "adw-gtk3", "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_paper_light.png",
                   "btopTheme": "/usr/share/btop/themes/paper.theme", "vscodeTheme": ["Paper", "Quiet Light"]},
    },
    "dark": {
        "surface": "#272520", "textPrimary": "#EEEADA", "textMuted": "#B3AE9E", "textFaint": "#7C786B",
        "accent": "#6FA3E8", "ok": "#7FB35F", "warn": "#D98A45", "spill": "#D6B045", "error": "#E8735E", "errorStrong": "#D5533D",
        "terminalSelection": "#4A473E",
        "hues": {"red": "#E8735E", "orange": "#D98A45", "yellow": "#D6B045", "green": "#7FB35F", "teal": "#4FB5AC", "sky": "#5FB0D6",
                 "blue": "#6FA3E8", "purple": "#A88BE0", "pink": "#D27FB4", "rose": "#E09488", "gray": "#8F8B7E"},
        "ansi": ["#3A3830", "#E8735E", "#7FB35F", "#D6B045", "#6FA3E8", "#A88BE0", "#4FB5AC", "#B3AE9E",
                 "#7C786B", "#F09482", "#9CCB7D", "#E8C766", "#93BBF0", "#C1A8EE", "#74CCC3", "#EEEADA"],
        "locked": "teal",
        "btop": {"hi_fg": "red", "selected_bg": "#4A473E", "selected_fg": "textPrimary", "proc_misc": "textPrimary",
                 "cpu_box": "textMuted", "mem_box": "textMuted", "net_box": "textMuted", "proc_box": "textMuted", "div_line": "textFaint",
                 "temp_start": "textFaint", "temp_mid": "textPrimary", "temp_end": "red", "cpu_start": "textFaint", "cpu_mid": "textPrimary",
                 "cpu_end": "red", "free_start": "green", "free_end": "green", "cached_start": "blue", "cached_end": "blue",
                 "available_start": "green", "available_end": "green", "used_start": "red", "used_end": "red", "download_start": "textFaint",
                 "download_mid": "textPrimary", "download_end": "red", "upload_start": "textFaint", "upload_mid": "textPrimary",
                 "upload_end": "red", "process_start": "textFaint", "process_mid": "textPrimary", "process_end": "red"},
        "assets": {"gtkTheme": ["Colloid-Dark", "adw-gtk3-dark"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_paper_dark.png",
                   "btopTheme": "paper-dark.theme", "vscodeTheme": "Kimbie Dark"},
    },
}

SPECS["riso"] = {
    "title": "Riso",
    "note": "Riso, the wildcard: a risograph print. Every other pair is an editor theme of greys with a pastel or neon accent; this one is ink on "
            "stock. Light: uncoated white paper, the text in Medium Blue ink, Fluorescent Pink as the accent, and the rest of the risograph ink "
            "list for the hues (Riso Green, Orange, Sunflower, Scarlet, Teal, Blue, Purple). Dark: the same inks printed on deep burgundy stock, "
            "the paper colour as the text. The colours are the published Riso ink approximations, darkened where text must read on paper. "
            "Group tabs: the tab is the orange, a locked group's tab Riso Blue. VS Code has no riso theme: Ros\u00e9 Pine Dawn / Moon "
            "(mvllow.rose-pine) when installed, else Light Modern and Red (the built-in dark red).",
    "light": {
        "surface": "#F3F0EA", "textPrimary": "#283C7E", "textMuted": "#4F5D94", "textFaint": "#8C94B8",
        "accent": "#EE3A9E", "ok": "#00A95C", "warn": "#FF6C2F", "spill": "#E09A00", "error": "#E0303A", "errorStrong": "#F65058",
        "terminalSelection": "#F7C6E0",
        "hues": {"red": "#E0303A", "orange": "#FF6C2F", "yellow": "#E09A00", "green": "#00A95C", "teal": "#00838A", "sky": "#0078BF",
                 "blue": "#3255A4", "purple": "#765BA7", "pink": "#FF48B0", "rose": "#F15060", "gray": "#88898A"},
        "ansi": ["#283C7E", "#E0303A", "#00A95C", "#E09A00", "#0078BF", "#EE3A9E", "#00838A", "#88898A",
                 "#3D5588", "#C4364A", "#237E74", "#BA8032", "#3255A4", "#AA60BF", "#009DA5", "#5F6577"],
        "locked": "sky",
        "cat": {"catFlatpak": "pink", "catAur": "sky"},
        "assets": {"gtkTheme": ["Colloid-Pink-Light", "XFCE_Colour_Lite_Pink"], "iconTheme": "Papirus-Light", "fastfetchLogo": "archlogo_riso_light.png",
                   "btopTheme": "riso-light.theme", "vscodeTheme": ["Ros\u00e9 Pine Dawn", "Light Modern"]},
    },
    "dark": {
        "surface": "#2D1B26", "textPrimary": "#F2EBE0", "textMuted": "#CDB7C2", "textFaint": "#8C6E7E",
        "accent": "#FF5CB8", "ok": "#5BD08A", "warn": "#FF8A4C", "spill": "#FFC23D", "error": "#FF5A4E", "errorStrong": "#FF3B30",
        "terminalSelection": "#5A3248",
        "hues": {"red": "#FF5A4E", "orange": "#FF8A4C", "yellow": "#FFC93C", "green": "#5BD08A", "teal": "#62C2B1", "sky": "#5EC8E5",
                 "blue": "#7AA6EC", "purple": "#B497E8", "pink": "#FF5CB8", "rose": "#FF8E91", "gray": "#A08A96"},
        "ansi": ["#4A2C3D", "#FF5A4E", "#5BD08A", "#FFC93C", "#7AA6EC", "#FF5CB8", "#5EC8E5", "#E6DCE0",
                 "#7A5A6B", "#FF8E91", "#8BE3A5", "#FFE16B", "#A3C3F4", "#F984CA", "#82D8D5", "#F2EBE0"],
        "locked": "sky",
        "cat": {"catFlatpak": "pink", "catAur": "sky"},
        "assets": {"gtkTheme": ["Colloid-Pink-Dark", "XFCE_Colour_Dark_Pink"], "iconTheme": "Papirus-Dark", "fastfetchLogo": "archlogo_riso_dark.png",
                   "btopTheme": "riso-dark.theme", "vscodeTheme": ["Ros\u00e9 Pine Moon", "Red"]},
    },
}


if __name__ == "__main__":
    sys.exit(main())
