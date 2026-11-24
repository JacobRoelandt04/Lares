#!/usr/bin/env python3
"""A sandbox HOME for themectl's tests -- and the proof that nothing outside it moved.

themectl's real `apply` writes kitty, btop, starship, Hyprland, GTK, fastfetch, wallpaper and hyprlock files and
signals programs. The old theme-switch.py does the same. NEITHER may ever run against the real HOME, so every run
of either one goes through this module:

    python3 tools/dev/themectl_sandbox.py make DIR [SEED]    build DIR: a HOME seeded with COPIES of the user's real files, or of the
                                                         fixture HOME SEED (a directory laid out like a home)
    python3 tools/dev/themectl_sandbox.py env DIR            the environment a program runs in there (KEY=VALUE lines)
    python3 tools/dev/themectl_sandbox.py run DIR -- CMD...  run CMD in that environment (nothing else of the caller's leaks)
    python3 tools/dev/themectl_sandbox.py manifest OUT.json  snapshot of the REAL paths a target or the old script writes
    python3 tools/dev/themectl_sandbox.py check BEFORE.json  compare the real paths with a snapshot: empty = nothing moved
    python3 tools/dev/themectl_sandbox.py stublog DIR        what the PATH stubs were called with (one call per line)

What the sandbox is:
  * HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_STATE_HOME, XDG_DATA_HOME all inside DIR/home.
  * PATH = DIR/bin : /usr/bin : /bin. DIR/bin holds a STUB for every program a target (or the old script) calls and
    that signals, restarts, retunes or draws on a running desktop: hyprctl, pkill, killall, kill, kitty, kitten, btop,
    awww, makoctl, waybar, xfconf-query, notify-send, systemctl, ... Each stub appends `name<TAB>arg<TAB>...` to
    $STUB_LOG and answers like the quiet success of the real one. The user's ~/.local/bin is NOT on the PATH.
  * GSETTINGS_BACKEND=keyfile: the REAL gsettings runs, and writes $XDG_CONFIG_HOME/glib-2.0/settings/keyfile, never
    dconf; DBUS_SESSION_BUS_ADDRESS=disabled: so no program can find the user's bus.
  * No WAYLAND_DISPLAY, no HYPRLAND_INSTANCE_SIGNATURE (the Hyprland target is proven in tools/dev/lock_env.sh's nested
    Hyprland, which hands its own signature to the one command that needs it).
  * The seed is a COPY. Text files are copied; images and other blobs become empty files of the same name (a
    wallpaper is only ever read by name here); a symlink that pointed inside the real HOME is re-pointed inside the
    sandbox, one that pointed elsewhere (/usr/share/themes/...) is kept.
  * The copy is of the user's real files unless the caller hands `make` a SEED: a fixture HOME (tools/dev/fixtures/themectl/home).
    A test seeded from the real files stops testing the day the desktop changes shape (the user's switch-over, 2026-10-22,
    turned nine checks of themectl_cases red); a seeded one does not read the real home at all, gsettings included.

The proof (`manifest` before, `check` after) is a stat-and-hash snapshot of every real path the targets or the old
script could write -- the app config directories, the old script's state file, dconf. It is stronger than
`find -newer`: a replaced file with an old mtime still changes its hash. The caller does not need to be quiet; a
path the real desktop itself rewrites meanwhile shows up, and then it is looked at, not waved through.
"""
import hashlib
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
sys.dont_write_bytecode = True

REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir          # the account's home, whatever HOME says

# What is copied into a sandbox HOME (relative to the real one). Directories are copied whole (text files only).
SEED = [
    ".config/kitty",
    ".config/btop/btop.conf",
    ".config/starship.toml",
    ".config/hypr",
    ".config/fastfetch",
    ".config/gtk-3.0",
    ".config/gtk-4.0",
    ".config/waybar/style.css",
    ".config/waybar/config.jsonc",
    ".config/mako/config",
    ".config/wofi",
    ".config/HyprV",
    ".config/Code/User/settings.json",
    ".config/theme/state.json",
    ".cache/theme_switcher_state.json",
]

# What the proof watches in the REAL home: every place a target or the old script writes, and dconf. HyprV is watched where
# the scripts only READ it (their symlinks point into it) but not waybar's data/ (its update checker rewrites that on its own).
WATCH = [
    ".config/kitty", ".config/btop", ".config/starship.toml", ".config/hypr", ".config/fastfetch",
    ".config/gtk-3.0", ".config/gtk-4.0", ".config/waybar", ".config/mako", ".config/wofi", ".config/wleave",
    ".config/HyprV/hyprlock", ".config/HyprV/starship", ".config/HyprV/waybar/style", ".config/HyprV/waybar/conf",
    ".config/HyprV/mako", ".config/HyprV/wofi", ".config/HyprV/wleave", ".config/HyprV/backgrounds",
    ".config/Code/User/settings.json", ".config/theme", ".config/dconf", ".config/glib-2.0",
    ".cache/theme_switcher_state.json", ".local/state/theme", ".config/windows/compose.yaml", "Documents/windows/.theme",
    ".config/yazi", ".config/nwg-look", ".local/share/nwg-look",
]

STUBS = ["hyprctl", "pkill", "killall", "kill", "kitty", "kitten", "btop", "awww", "awww-daemon", "makoctl", "mako",
         "waybar", "wofi", "xfconf-query", "notify-send", "systemctl", "busctl", "dbus-send", "gdbus", "hyprpm",
         "hyprlock", "hypridle", "swaync", "dunstctl", "code", "fastfetch", "starship", "mpc", "hyprpaper"]

STUB_SH = r"""#!/bin/sh
# A stub for a program that signals, restarts or draws on a running desktop: it only writes down how it was called.
name=$(basename "$0")
{
    printf '%s' "$name"
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "${STUB_LOG:-/dev/null}"
case "$name" in
    pkill|killall) exit "${STUB_PKILL_RC:-0}" ;;
    hyprctl) if [ "${1:-}" = hyprpaper ]; then
                 # forced answers (a daemon that is down, an error) win; otherwise a model of hyprpaper 0.8.5: a fallback picture and one per
                 # NAMED monitor in $STUB_HYPRPAPER_STATE (lines `<monitor or *>\t<path>`), the named one beating the fallback until the daemon
                 # restarts (measured: tools/dev/themectl_hyprpaper_env_probe.sh); a request it ignores answers exit 0 and nothing.
                 # $STUB_HYPRPAPER_MONITORS (default eDP-1) are listed; a monitor in $STUB_HYPRPAPER_STUCK takes no request by name.
                 if [ -n "${STUB_HYPRPAPER_OUT:-}" ] || [ -n "${STUB_HYPRPAPER_RC:-}" ]; then
                     [ -n "${STUB_HYPRPAPER_OUT:-}" ] && echo "$STUB_HYPRPAPER_OUT"; exit "${STUB_HYPRPAPER_RC:-0}"
                 fi
                 st="${STUB_HYPRPAPER_STATE:-/dev/null}"
                 case "${2:-}" in
                     wallpaper) mon="${3%%,*}"; rest="${3#*,}"; pic="${rest%,*}"
                                [ -f "$pic" ] || { echo "error: bad path: $pic"; exit 1; }
                                for s in ${STUB_HYPRPAPER_STUCK:-}; do [ "$s" = "$mon" ] && exit 0; done
                                key="${mon:-*}"
                                { awk -F'\t' -v k="$key" '$1 != k' "$st" 2>/dev/null; printf '%s\t%s\n' "$key" "$pic"; } > "$st.new" && mv "$st.new" "$st" ;;
                     listactive) for m in ${STUB_HYPRPAPER_MONITORS-eDP-1}; do
                                     pic=$(awk -F'\t' -v k="$m" '$1 == k { p = $2 } END { print p }' "$st" 2>/dev/null)
                                     [ -n "$pic" ] || pic=$(awk -F'\t' '$1 == "*" { p = $2 } END { print p }' "$st" 2>/dev/null)
                                     [ -n "$pic" ] && echo "$m: $pic"
                                 done ;;
                 esac
                 exit 0
             fi
             if [ "${1:-}" = eval ] || [ "${1:-}" = reload ]; then echo "${STUB_HYPRCTL_OUT:-ok}"; fi; exit "${STUB_HYPRCTL_RC:-0}" ;;
    awww) exit "${STUB_AWWW_RC:-0}" ;;
esac
exit 0
"""


def _is_blob(name, size):
    ext = os.path.splitext(name)[1].lower()
    return ext in (".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".so", ".ttf", ".otf") or size > 400_000


def _rebase(target, sb_home):
    if target == REAL_HOME or target.startswith(REAL_HOME + "/"):
        return sb_home + target[len(REAL_HOME):]
    return target


def _copy_entry(src, dst, sb_home):
    """Copy one file, symlink or directory of the real home into the sandbox (text copied, blobs emptied)."""
    st = os.lstat(src)
    if stat.S_ISLNK(st.st_mode):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.lexists(dst):
            os.remove(dst)
        os.symlink(_rebase(os.readlink(src), sb_home), dst)
    elif stat.S_ISDIR(st.st_mode):
        os.makedirs(dst, exist_ok=True)
        for n in sorted(os.listdir(src)):
            _copy_entry(os.path.join(src, n), os.path.join(dst, n), sb_home)
    else:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if _is_blob(os.path.basename(src), st.st_size):
            open(dst, "wb").close()
        else:
            shutil.copyfile(src, dst)


def make(root, seed=None):
    """Build the sandbox in ROOT (created fresh). Returns the environment dict programs run in.

    SEED: a directory laid out like a HOME, copied whole (the same rules as the real files: text copied, blobs emptied, links
    re-pointed) instead of the user's own files; the real home and its gsettings are then not read at all. None: copies of the
    real files (the SEED list above) and a keyfile from the real gsettings -- the runners that compare against the old script, which
    reads the real desktop on purpose, take that."""
    root = os.path.realpath(root)
    # rmtree below: never of the home, an ancestor of it, or anything in its config
    if (root == REAL_HOME or REAL_HOME.startswith(root.rstrip("/") + "/")
            or root.startswith(os.path.join(REAL_HOME, ".config") + "/")):
        raise RuntimeError("refusing to build a sandbox at %s" % root)
    if os.path.exists(root):
        shutil.rmtree(root)
    sb = os.path.join(root, "home")
    for d in (".config", ".cache", ".local/state", ".local/share", ".local/bin"):
        os.makedirs(os.path.join(sb, d), exist_ok=True)
    if seed is not None:
        if not os.path.isdir(seed):
            raise RuntimeError("no fixture home at %s" % seed)
        _copy_entry(os.path.realpath(seed), sb, sb)
    else:
        for rel in SEED:
            src = os.path.join(REAL_HOME, rel)
            if os.path.lexists(src):
                _copy_entry(src, os.path.join(sb, rel), sb)
    bindir = os.path.join(root, "bin")
    os.makedirs(bindir)
    for n in STUBS:
        p = os.path.join(bindir, n)
        with open(p, "w") as f:
            f.write(STUB_SH)
        os.chmod(p, 0o755)
    open(os.path.join(root, "stub.log"), "w").close()
    if seed is None:
        _seed_gsettings(sb)
    return env_of(root)


def _seed_gsettings(sb):
    """The keyfile backend starts from what the user's gsettings say now (a read of the real thing)."""
    keys = ["gtk-theme", "icon-theme", "color-scheme"]
    lines = ["[org/gnome/desktop/interface]"]
    for k in keys:
        try:
            v = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", k], capture_output=True, text=True,
                               timeout=10, env={"PATH": "/usr/bin:/bin", "HOME": REAL_HOME,
                                                "DBUS_SESSION_BUS_ADDRESS": os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")}
                               ).stdout.strip()
        except Exception:
            v = ""
        if v:
            lines.append("%s=%s" % (k, v))
    d = os.path.join(sb, ".config", "glib-2.0", "settings")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "keyfile"), "w") as f:
        f.write("\n".join(lines) + "\n")


def env_of(root):
    root = os.path.abspath(root)
    sb = os.path.join(root, "home")
    return {
        "HOME": sb,
        "XDG_CONFIG_HOME": sb + "/.config",
        "XDG_CACHE_HOME": sb + "/.cache",
        "XDG_STATE_HOME": sb + "/.local/state",
        "XDG_DATA_HOME": sb + "/.local/share",
        "PATH": root + "/bin:/usr/bin:/bin",
        "GSETTINGS_BACKEND": "keyfile",
        "DBUS_SESSION_BUS_ADDRESS": "disabled:",
        "STUB_LOG": root + "/stub.log",
        "STUB_HYPRPAPER_STATE": root + "/hyprpaper.state",
        "LANG": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
        "USER": os.environ.get("USER", "user"),
    }


def run(root, argv, extra=None, **kw):
    """Run ARGV inside the sandbox: its environment is the sandbox's and nothing of the caller's."""
    env = env_of(root)
    env.update(extra or {})
    if os.path.realpath(env["HOME"]) == os.path.realpath(REAL_HOME):
        raise RuntimeError("refusing: the sandbox HOME is the real one")
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw.setdefault("stdin", subprocess.DEVNULL)
    return subprocess.run(argv, env=env, **kw)


def stublog(root):
    """[[name, arg, ...], ...] in call order."""
    out = []
    try:
        with open(os.path.join(root, "stub.log")) as f:
            for line in f:
                line = line.rstrip("\n")
                if line:
                    out.append(line.split("\t"))
    except OSError:
        pass
    return out


def clear_stublog(root):
    open(os.path.join(root, "stub.log"), "w").close()


# ---------------------------------------------------------------------------------------------- the proof

def _snap(path):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    e = {"mode": stat.S_IFMT(st.st_mode), "size": st.st_size, "mtime": st.st_mtime_ns}
    if stat.S_ISLNK(st.st_mode):
        e["link"] = os.readlink(path)
    elif stat.S_ISREG(st.st_mode) and st.st_size <= 2_000_000:
        h = hashlib.sha1()
        try:
            with open(path, "rb") as f:
                h.update(f.read())
            e["sha1"] = h.hexdigest()
        except OSError:
            pass
    return e


def manifest():
    m = {}
    for rel in WATCH:
        base = os.path.join(REAL_HOME, rel)
        if not os.path.lexists(base):
            m[rel] = None
            continue
        if os.path.isdir(base) and not os.path.islink(base):
            for dp, dns, fns in os.walk(base):
                m[os.path.relpath(dp, REAL_HOME)] = _snap(dp)
                for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
                    p = os.path.join(dp, n)
                    m[os.path.relpath(p, REAL_HOME)] = _snap(p)
        else:
            m[rel] = _snap(base)
    return m


def compare(before, after):
    """[(path, what)] -- empty when nothing moved. A directory's own mtime moves with its entries: reported only
    when the set of entries is the same (a file changing inside is reported by the file)."""
    out = []
    for p in sorted(set(before) | set(after)):
        a, b = before.get(p), after.get(p)
        if a == b:
            continue
        if a is None:
            out.append((p, "appeared"))
        elif b is None:
            out.append((p, "disappeared"))
        else:
            fields = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
            out.append((p, "changed: " + ", ".join(fields)))
    return out


def _main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "make":
        env = make(argv[2], argv[3] if len(argv) > 3 else None)
        print("sandbox ready:", env["HOME"])
        return 0
    if cmd == "env":
        for k, v in sorted(env_of(argv[2]).items()):
            print("%s=%s" % (k, v))
        return 0
    if cmd == "run":
        root = argv[2]
        rest = argv[3:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        return run(root, rest, capture_output=False).returncode
    if cmd == "manifest":
        with open(argv[2], "w") as f:
            json.dump(manifest(), f)
        return 0
    if cmd == "check":
        with open(argv[2]) as f:
            before = json.load(f)
        diffs = compare(before, manifest())
        for p, w in diffs:
            print("MOVED  ~/%s  %s" % (p, w))
        print("THEMECTL_OUTSIDE %s" % ("clean: nothing outside the sandbox changed" if not diffs else "DIRTY (%d)" % len(diffs)))
        return 1 if diffs else 0
    if cmd == "stublog":
        for c in stublog(argv[2]):
            print(" ".join(c))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
