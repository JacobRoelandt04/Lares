#!/usr/bin/env python3
"""config_effective.py -- what a directory of jsonc configs comes to in the code, key by key.

    python3 tools/dev/config_effective.py <dir> > effective.txt

Prints one line per effective value, sorted: `<file>.<property>.<key...> = <json>  [set|default]`, where [set] means it differs from what
the same code answers for an empty directory. The real loaders are what is asked (ShellConfig, NotificationConfig, OsdConfig, SiliconConfig,
LauncherConfig, StocksConfig, WeatherConfig, WindowTrayConfig, IdleConfig, LlmConfig, offscreen in a sandbox copy, every public property
they declare; clipboard is read by its Python tool's own `load`), so the printout is the code's defaults merged with the file, not the file.

THE SAME KEYS FROM EITHER SIDE OF C4. A tree that has no IdleConfig / LlmConfig loader (the tree before C4) is asked the same questions
through what read them there: `idle.settings` is IdleConfig.js's parse of shell.jsonc's `idle`, `llm.store` / `llm.notePrompt` are
ShellConfig's llmStore and the raw `llm.notePrompt`. `scale.*` is ScaleConfig.js's parse of shell.jsonc in both, and `scale.llmRatio` the
LLM popup's size: LlmScale.js's ratio before, the `llm` entry of the popups' map after. tools/dev/config_migrate_proof.py runs this file in
a tree of each kind and compares.

Only these names are ever read from <dir>, in that order of preference `.jsonc`, `.json`: calendars and .env are not among them. Nothing
is written beside them. No network: `curl` is a stub that fails (the weather loader geocodes its places; `_raw` is what the file says).
"""
import copy
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# file -> the loader's type, its path property
LOADERS = {
    "shell": ("ShellConfig", "configPath"),
    "notifications": ("NotificationConfig", "configPath"),
    "osd": ("OsdConfig", "configPath"),
    "silicon": ("SiliconConfig", "configPath"),
    "launcher": ("LauncherConfig", "path"),
    "stocks": ("StocksConfig", "configPath"),
    "weather": ("WeatherConfig", "configPath"),
    "windowtray": ("WindowTrayConfig", "configPath"),
    "idle": ("IdleConfig", "configPath"),
    "llm": ("LlmConfig", "configPath"),
}
OPTIONAL = {"idle", "llm"}     # a tree before C4 has neither: the same values are asked through shell.jsonc (DERIVED)
NAMES = list(LOADERS) + ["clipboard"]
SKIP = {"live", "configPath", "path", "examplePath", "lastError", "error", "present", "exists", "serial", "fontFamily"}
EXTRA = {"weather": ["_raw"]}


def source_of(typ, optional=False):
    hits = [p for p in glob.glob("modules/**/" + typ + ".qml", recursive=True)]
    if optional and not hits:
        return None
    if len(hits) != 1:
        raise SystemExit(f"config_effective: {typ}.qml found {len(hits)} times")
    return hits[0]


def js_of(name):
    hits = glob.glob("modules/**/" + name, recursive=True)
    return hits[0] if len(hits) == 1 else None


def harness(dirs):
    """The QML: one bundle of loaders per directory, each dumped once as `CE <tag> <file> <json>` lines."""
    imports, bodies, props, present = [], [], {}, []
    for name, (typ, key) in LOADERS.items():
        src = source_of(typ, name in OPTIONAL)
        if src is None:
            continue
        present.append(name)
        d = os.path.dirname(src)
        line = f'import "{d}"'
        if line not in imports:
            imports.append(line)
        text = open(src, encoding="utf-8").read()
        found = re.findall(r"^    (?:readonly )?property \S+ ([a-z]\w*)", text, re.M)
        props[name] = [p for p in found if p not in SKIP] + EXTRA.get(name, [])
        bodies.append(f'            {typ} {{ id: l_{name}; {key}: b.dir + "/{name}.jsonc" }}')
    pairs = ", ".join(f'"{n}": l_{n}' for n in present)
    js = {"idlecfg": js_of("IdleConfig.js"), "scalecfg": js_of("ScaleConfig.js"), "llmscale": js_of("LlmScale.js")}
    for alias, path in js.items():
        if path:
            imports.append(f'import "{path}" as {alias.capitalize()}')
    old_idle = "idle" not in present
    old_llm = "llm" not in present
    derived = f'''
            function derived() {{
                const raw = l_shell.raw || {{}};
                const home = Quickshell.env("HOME") || "";
                {"root.dumpObj(b.tag, {settings: Idlecfg.parse(raw.idle, home)}, 'idle');" if old_idle else ""}
                {"root.dumpObj(b.tag, {store: l_shell.config.llmStore, notePrompt: String(((raw.llm || {}).notePrompt) || '')}, 'llm');" if old_llm else ""}
                const sp = Scalecfg.parse(raw);
                const llm = {"Llmscale.ratio(raw, '')" if js["llmscale"] else "Scalecfg.popupMap(sp, '').llm"};
                root.dumpObj(b.tag, {{ parsed: sp, llmRatio: llm }}, "scale");
            }}'''
    return f'''import QtQuick
import Quickshell
{chr(10).join(imports)}
Scope {{
    id: root
    readonly property var names: {json.dumps(props)}
    function dump(tag, o, file) {{
        const out = {{}};
        for (const p of root.names[file]) {{
            const v = o[p];
            if (typeof v === "function" || v === undefined)
                continue;
            try {{
                out[p] = JSON.parse(JSON.stringify(v));
            }} catch (e) {{
                out[p] = "<" + String(v) + ">";
            }}
        }}
        console.log("CE " + tag + " " + file + " " + JSON.stringify(out));
    }}
    function dumpObj(tag, o, file) {{
        console.log("CE " + tag + " " + file + " " + JSON.stringify(o));
    }}
    Component {{
        id: bundle
        Item {{
            id: b
            property string dir
            property string tag
{chr(10).join(bodies)}
            function all() {{
                const m = {{ {pairs} }};
                for (const k in m)
                    root.dump(b.tag, m[k], k);
                b.derived();
            }}
{derived}
        }}
    }}
    property var items: []
    Component.onCompleted: {{
        const dirs = {json.dumps(dirs)};
        for (const t in dirs)
            root.items.push(bundle.createObject(host, {{ dir: dirs[t], tag: t }}));
    }}
    Item {{ id: host }}
    Timer {{
        running: true
        interval: 2500
        onTriggered: {{
            for (const it of root.items)
                it.all();
            console.log("CE END");
            quit.start();
        }}
    }}
    Timer {{
        id: quit
        interval: 0
        onTriggered: Qt.quit()
    }}
}}
'''


def flatten(prefix, v, out):
    if isinstance(v, dict) and v:
        for k in v:
            flatten(f"{prefix}.{k}", v[k], out)
    else:
        out[prefix] = json.dumps(v, sort_keys=True, ensure_ascii=False)


def clipboard(path):
    sys.path.insert(0, os.path.join(os.getcwd(), "tools", "clipboard"))
    from lib import config  # the tool's own merge
    return config.load(path)


def inner(work):
    if os.path.exists(".git"):
        raise SystemExit("config_effective: --inner writes a QML file where it stands: a sandbox copy only")
    dirs = {"with": os.path.join(work, "with"), "none": os.path.join(work, "none")}
    qml = "config_effective_generated.qml"
    open(qml, "w", encoding="utf-8").write(harness(dirs))
    stub = os.path.join(work, "stub")
    os.makedirs(stub)
    with open(os.path.join(stub, "curl"), "w") as f:
        f.write("#!/bin/sh\nexit 7\n")
    os.chmod(os.path.join(stub, "curl"), 0o755)
    home = {k: os.path.join(work, "x" + k) for k in ("config", "state", "cache", "data", "rt")}
    for p in home.values():
        os.makedirs(p)
    os.chmod(home["rt"], 0o700)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", "user"), "PATH": stub + ":" + os.environ["PATH"], "DISPLAY": os.environ.get("DISPLAY", ""),
           "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "rhi", "QS_DISABLE_CRASH_HANDLER": "1", "QS_DISABLE_FILE_WATCHER": "1",
           "XDG_CONFIG_HOME": home["config"], "XDG_STATE_HOME": home["state"], "XDG_CACHE_HOME": home["cache"], "XDG_DATA_HOME": home["data"], "XDG_RUNTIME_DIR": home["rt"]}
    log = os.path.join(work, "log")
    with open(log, "wb") as f:
        subprocess.run(["tools/dev/notifications_bus.sh", "timeout", "-k", "5", "90", "quickshell", "-p", qml], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)
    got = {"with": {}, "none": {}}
    ended = False
    for raw in open(log, errors="replace"):
        s = re.sub(r"\x1b\[[0-9;]*m", "", raw)
        m = re.search(r"CE (with|none) (\w+) (\{.*\})\s*$", s)
        if m:
            got[m.group(1)][m.group(2)] = json.loads(m.group(3))
        elif "CE END" in s:
            ended = True
    if not ended or any(n not in got[t] for t in got for n in list(LOADERS) + ["scale"]):
        sys.stderr.write(f"config_effective: the harness did not answer (log: {log})\n" + open(log, errors="replace").read()[-1500:])
        return 1
    for t in got:
        p = os.path.join(dirs[t], "clipboard.jsonc")
        got[t]["clipboard"] = {"config": copy.deepcopy(clipboard(p if os.path.exists(p) else os.path.join(dirs[t], "none.jsonc")))}
    a, b = {}, {}
    for f in NAMES + ["scale"]:
        flatten(f, got["with"][f], a)
        flatten(f, got["none"][f], b)
    for k in sorted(a):
        print(f"{k} = {a[k].replace(work, '<run>')}  [{'default' if b.get(k) == a[k] else 'set'}]")
    for k in sorted(set(b) - set(a)):
        if not any(o.startswith(k + ".") for o in a):        # an empty default the file filled in
            print(f"{k} = (absent; default {b[k].replace(work, '<run>')})  [set]")
    return 0


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--inner":
        return inner(a[1])
    if len(a) != 1 or not os.path.isdir(a[0]):
        print(__doc__)
        return 2
    src = os.path.abspath(a[0])
    scratch = os.environ.get("SCRATCH", "/tmp/lares-cleanup")
    os.makedirs(scratch, exist_ok=True)
    work = tempfile.mkdtemp(prefix="cfgeff.", dir=scratch)
    try:
        for t in ("with", "none"):
            os.makedirs(os.path.join(work, t))
        for n in NAMES:
            for ext in (".jsonc", ".json"):
                p = os.path.join(src, n + ext)
                if os.path.isfile(p):
                    shutil.copy(p, os.path.join(work, "with", n + ext))
                    break
        os.chdir(ROOT)
        env = dict(os.environ)
        env.setdefault("SANDBOX", os.path.join(scratch, "lares-sandbox-cleanup"))
        return subprocess.run(["tools/dev/sandbox.sh", "-u", "WAYLAND_DISPLAY", "-u", "HYPRLAND_INSTANCE_SIGNATURE", "QT_QPA_PLATFORM=offscreen", "MOCKUP_REPO=",
                               "python3", "-B", "tools/dev/config_effective.py", "--inner", work], env=env).returncode
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
