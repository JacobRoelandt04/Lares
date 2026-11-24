#!/usr/bin/env python3
"""The faults tools/dev/aerial_tunnel_probe.sh arms, put into the tree it stands in (a sandbox copy: the runner starts itself inside one).
Exit 1 when an anchor is not in the code exactly once (an arm that patches nothing proves nothing), 2 for an unknown arm."""
import sys

arm = sys.argv[1]
p = "modules/aerial/scene/AerialLabel.qml"
if arm in ("nolead",):
    p = "modules/aerial/popup/AerialPopup.qml"
elif arm in ("notilt",):
    p = "modules/aerial/scene/AerialScene.qml"
s = open(p, encoding="utf-8").read()


def rep(a, b):
    global s
    if s.count(a) != 1:
        print("anchor found %d times: %s" % (s.count(a), a.splitlines()[0][:90]))
        sys.exit(1)
    s = s.replace(a, b)


WAIT = "            if (!r)\n                return;                             // (a row is not built yet: its arrival calls again)\n"
if arm == "snap":
    # the wipe's own gate says "being built" for ever (what the desktop had)
    rep("        const to = root._vpn ? 1 : 0;\n        if (!root.animate || !root._built) {", "        const to = root._vpn ? 1 : 0;\n        if (true) {")
elif arm == "lastfirst":
    # round 3's placement: it reads rows that are not there yet
    rep(WAIT, "")
elif arm == "builtlast":
    # that, with the flag set after the placement: a throw in the completion leaves the label "being built"
    rep(WAIT, "")
    rep("        root._built = true;\n        root._sync();", "        root._sync();\n        root._built = true;")
elif arm == "viaquick":
    # the via line opens on its own quick clock while the wipe runs (round 3)
    rep("            viaAnim.duration = withWipe ? chromeAnim.duration : 260;", "            viaAnim.duration = 260;")
elif arm == "viastale":
    # the handler reads the `_vpn` binding, which has not followed the facts yet when it runs
    rep("            const vpnNow = !!root.label && root.label.vpn === true;", "            const vpnNow = root._vpn;")
elif arm == "quick":
    # round 3's 750 ms wipe (the user asked for twice that)
    rep("        duration: 1500\n        easing.type: Easing.InOutSine", "        duration: 750\n        easing.type: Easing.InOutSine")
elif arm == "nolead":
    # the pointer is never told to the room in the chrome
    rep("            root._leadTo(x, y);\n", "")
elif arm == "notilt":
    # the plate never hears of the card's tilt
    rep("        tilt: root.cardTilt\n        lead: root.lead", "        tilt: 0\n        lead: root.lead")
else:
    print("unknown ARM=" + arm)
    sys.exit(2)
open(p, "w", encoding="utf-8").write(s)
