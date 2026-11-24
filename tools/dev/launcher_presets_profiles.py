#!/usr/bin/env python3
"""Write the confirm flourish's presets (modules/launcher/FlourishPresets.js) as launcher mockup profiles.

  tools/dev/launcher_presets_profiles.py [<profiles-dir>]     default: mockup_profiles/launcher next to this repo

One profile per preset, named for it ("honey", "syrup", "dew", "classic"), holding the preset's values as
`confirmParams` -- the Profiles tab's Load then sets exactly those entries and leaves every other value alone.
`mockup_profiles/` is untracked runtime state (.gitignore), so a checkout does not carry them: run this where
the mockup runs (for the user's own: tools/dev/launcher_presets_profiles.py ~/.config/quickshell/mockup_profiles/launcher).
Same file format as the panel's own Save (tools/dev/mockup_profiles.py save).
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# The presets' own numbers, read from the module (the one place they live).
PRESETS_JS = os.path.join(HERE, "..", "..", "modules", "launcher", "FlourishPresets.js")


def presets():
    src = open(PRESETS_JS, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^    (\w+): \{(.*?)^    \}", src, re.S | re.M):
        out[m.group(1)] = {k: float(v) for k, v in re.findall(r"(\w+): (-?[\d.]+)", m.group(2))}
    return out


d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "mockup_profiles", "launcher")
for name, vals in presets().items():
    payload = json.dumps({"confirmParams": {k: (int(v) if float(v).is_integer() else v) for k, v in vals.items()}})
    subprocess.run([sys.executable, os.path.join(HERE, "mockup_profiles.py"), "save", d, name, payload], check=True)
