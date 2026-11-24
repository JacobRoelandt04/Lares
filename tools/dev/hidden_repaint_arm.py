#!/usr/bin/env python3
"""The faults tools/dev/hidden_repaint_env_probe.sh puts into a COPY of tools/theme/hidden_repaint.py, one per run.

    hidden_repaint_arm.py --list              the arms' names
    hidden_repaint_arm.py --needle <arm>      the check (an ERE on the driver's own words) that must fail under that arm
    hidden_repaint_arm.py <arm> <copy.py>     patch the copy; exit 1 when the anchor is gone (the arm proves nothing then)

norun is the runner's own (the tool is not run at all): every "no stale frame" check must fail, or the film sees nothing.
"""
import sys

ARMS = {
    # name: (needle, [(old, new), ...])
    "norun": ("no stale frame: a hidden workspace \\(GTK\\)", []),
    # HR_MODE=vscode with no class entry for VS Code (the runner sets both): it gets the default frame, as every window
    "noclassframes": ("VS Code comes back in the new colours", []),
    "noframes": ("no stale frame", [
        # every step in one turn of the compositor: no frame is drawn between them, so nothing is ever really shown
        ('    R.timer = hl.timer(step, { timeout = steps[R.i][2], type = "oneshot" })', '    step()'),
    ]),
    # (the needle is the HIDDEN workspace's group: in the probe's session the shown group's hidden tabs are also repainted by the
    # trip to workspace 3 and back, so that check stays green without the flips; measured 2026-11-21)
    "notabs": ("no stale frame: a hidden workspace's group and its hidden tab", [
        ('        groups = _groups(clients, ws_name)\n        lists = ', '        groups = []\n        lists = '),
    ]),
    "nospecial": ("no stale frame: the special workspace", [
        ('        hidden = [w for w in hidden if not w.get("hasfullscreen")]',
         '        hidden = [w for w in hidden if not w.get("hasfullscreen") and not is_special(w)]'),
    ]),
    "nohome": ("state: workspaces", [
        ('            back.append(("ws", name, ws_key(ws_by_name.get(active, m["activeWorkspace"]))))', '            pass'),
    ]),
    "notabsback": ("state: tabs", [
        ('        undo = [("tab", g["shown"], g["members"].index(g["shown"]) + 1) for g, o in zip(groups, lists) if o]',
         '        undo = []'),
    ]),
    "noanimback": ("state: animations", [
        ('    try(function() hl.config({ animations = { enabled = anim }, cursor = { no_warps = warps } }) end)',
         '    try(function() hl.config({ cursor = { no_warps = warps } }) end)'),
    ]),
    # HR_MODE=interrupt (the runner reads the mode from --mode): the user changes workspace under the run
    "nostop": ("the user's workspace stands", [
        ('    if moved() then tabs_back(); finish("stopped"); return end', ''),
    ]),
    "notabsstop": ("state: tabs", [
        ('    if moved() then tabs_back(); finish("stopped"); return end', '    if moved() then finish("stopped"); return end'),
    ]),
    # the cases' own (tools/dev/hidden_repaint_cases.py ARM=all): the class table is not read; a step takes its FIRST window's
    # frames, not the most; a class matches by a part of it; showing a workspace counts its hidden tabs
    "noclass": ("11 ", [
        ('        if key in class_frames:\n            return class_frames[key]', '        if False:\n            return class_frames[key]'),
    ]),
    "nomax": ("11 a step stays the most", [
        ('        need.append(max([frames_of(c, frames, lower) for c in wins] or [frames]))',
         '        need.append(([frames_of(c, frames, lower) for c in wins] or [frames])[0])'),
    ]),
    "substring": ("11b ", [
        ('        if key in class_frames:\n            return class_frames[key]',
         '        for k in class_frames:\n            if k in key:\n                return class_frames[k]'),
    ]),
    "hiddentabs": ("11c ", [
        ('        return [c for c in by_ws.get(ws_name, []) if c["address"] not in hidden_tabs]', '        return list(by_ws.get(ws_name, []))'),
    ]),
    "warps": ("the pointer never moved during the run", [
        ('try(function() hl.config({ animations = { enabled = false }, cursor = { no_warps = true } }) end)',
         'try(function() hl.config({ animations = { enabled = false } }) end)'),
    ]),
}

CASE_ARMS = ("noclass", "nomax", "substring", "hiddentabs")


def main(argv):
    if len(argv) == 2 and argv[1] == "--list":
        print(" ".join(a for a in ARMS if a not in CASE_ARMS))       # those are the case table's (hidden_repaint_cases.py)
        return 0
    if len(argv) == 3 and argv[1] == "--needle":
        print(ARMS[argv[2]][0])
        return 0
    if len(argv) == 3 and argv[1] == "--mode":
        print("interrupt" if argv[2] in ("nostop", "notabsstop") else ("vscode" if argv[2] == "noclassframes" else ""))
        return 0
    arm, path = argv[1], argv[2]
    if arm not in ARMS:
        print("unknown ARM " + arm)
        return 1
    text = open(path).read()
    for old, new in ARMS[arm][1]:
        if text.count(old) != 1:
            print("ARM %s: its anchor is gone (%r found %d times)" % (arm, old[:60], text.count(old)))
            return 1
        text = text.replace(old, new)
    open(path, "w").write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
