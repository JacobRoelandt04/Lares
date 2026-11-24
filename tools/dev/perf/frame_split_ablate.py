#!/usr/bin/env python3
"""frame_split_ablate.py -- the patches tools/dev/perf/frame_split.sh applies to ITS OWN SANDBOX COPY before it starts the shell.

    frame_split_ablate.py <tree> <name> ...

`livetitle` is the runner's own too (always applied): the mock shell's window title follows the NESTED compositor's windows
(ActiveWindowService, live) where SHELL_FOCUS=live -- without it a title: / focus: scenario moves nothing and "the islands cost
nothing" (pass 1's reading of them was that). `hooktoggle` is the runner's own (always applied): a mock-only `hook toggle <owner key>` in modules/shell/ShellMain.qml (shell.qml's body), so a scenario can open and
close any owner's popup, and `hook wikiopen <discover|deepen>` (the clock popup with its wiki SECONDARY, as a notification's click asks). Every other name is an ABLATION: one thing turned off to price it (ABL="name ..."). A patch whose anchor is
gone fails the run before anything starts -- an ablation that silently patched nothing would read as "costs nothing".
Refuses a tree that is a git work tree: it only ever patches a sandbox copy.
"""
import os
import sys

PATCHES = {
    # not an ablation, a LOG: which term keeps a body's clip layer on once it is open (GooeyEngine._applyClip), one `FS clip` line per layout
    "cliplog": [("modules/bar/gooey/GooeyEngine.qml", "        S.clipOn = on;\n",
                 "        if (S.phase === \"open\")\n"
                 "            console.log(\"FS clip child=\" + (S.isChild === true) + \" edge=\" + S.edge + \" on=\" + on + \" force=\" + engine.forceContentClip\n"
                 "                + \" corner=\" + (r.ex.some(v => v > rest) || r.ey.some(v => v > rest)) + \" rect=\" + [r.x0 - S.popX, r.y0 - S.popY, r.x1 - S.popX - S.popW, r.y1 - S.popY - S.popH].map(v => v.toFixed(2)).join(\"/\")\n"
                 "                + \" float=\" + engine._floatOf(S).toFixed(3) + \" live=\" + engine._liveOf(S) + \" ex=\" + r.ex.map(v => v.toFixed(1)).join(\"/\") + \" ey=\" + r.ey.map(v => v.toFixed(1)).join(\"/\") + \" rest=\" + rest.toFixed(1) + \" box=\" + Math.round(S.popW) + \"x\" + Math.round(S.popH));\n"
                 "        S.clipOn = on;\n")],
    # the engine's start-up prewarm (ShellFrame builds every recyclable popup content once, ~6 s after the start)
    "noprewarm": [("modules/shell/ShellFrame.qml", "    property bool prewarm: true\n", "    property bool prewarm: false\n")],
    # OSD first-frame ablations (perf2 stream CONTENT): ONE build each left out of the run's copy, priced by the first frames of `osd:<n>`
    "osdnosparks": [("modules/osd/kinds/OsdLevel.qml", "    OsdSparks {\n        id: sparks\n",
                     "    Item {\n        id: sparks\n        property var style\n        property color color\n        function shed(x, y, dx, dy) {}\n")],
    "osdnoslidefx": [("modules/common/components/GrooveSlider.qml", "        MultiEffect {\n            source: slideParticles\n",
                      "        Item {\n            property var source\n            property bool blurEnabled\n            property real blurMax\n            property real blur\n            property real brightness\n")],
    "osdnoparticles": [("modules/common/components/GrooveSlider.qml", "            id: slideParticles\n            anchors.fill: parent\n            maxParticles: 500\n",
                        "            id: slideParticles\n            anchors.fill: parent\n            maxParticles: 1\n"),
                       ("modules/common/components/GrooveSlider.qml", "            id: burstParticles\n            anchors.fill: parent\n            maxParticles: 200\n",
                        "            id: burstParticles\n            anchors.fill: parent\n            maxParticles: 1\n")],
    # not an ablation, a LOG (stream ENGINE, perf pass 2): what building a child's and the OSD's content costs in the turn that asks
    # for it (both are built by the body's Loader, synchronously, at the assignment): `FS build child|osd <ms>`
    "buildlog": [("modules/bar/gooey/GooeyEngine.qml", "        C.component = component;\n",
                  "        const fsT0 = Date.now();\n"
                  "        C.component = component;\n"
                  "        console.log(\"FS build child \" + (Date.now() - fsT0));\n"),
                 ("modules/bar/gooey/GooeyEngine.qml", "            S.contentOpacity = 0;\n            S.component = req.component;\n",
                  "            S.contentOpacity = 0;\n            const fsT0 = Date.now();\n            S.component = req.component;\n"
                  "            console.log(\"FS build osd \" + (Date.now() - fsT0));\n")],
    # not an ablation, a LOG (stream ENGINE): a stand-in interaction boost that prints every kick the engine sends (`FS boost <ms>`)
    "boostlog": [("modules/shell/ShellFrame.qml", "        boost: frame.services.boost ?? null\n",
                  "        boost: ({ kick: function (ms) { console.log(\"FS boost \" + ms); } })\n")],
    # perf2 stream FIRSTDRAW: silicon's first draw in the warm-up, priced part by part (one part of SiliconScene left out each), and
    # `sitwice` (silicon's entry warmed twice: what repeats is drawing, what does not is a one-time link)
    "sitwice": [("modules/shell/ShellFrame.qml",
                 "            entries.push({ ownerId: siliconOwner.ownerId, component: siliconOwner.popupComponent, initial: { parked: true, prewarm: true } });\n",
                 "            entries.push({ ownerId: siliconOwner.ownerId, component: siliconOwner.popupComponent, initial: { parked: true, prewarm: true } });\n"
                 "        if (siliconOwner.svc)\n"
                 "            entries.push({ ownerId: siliconOwner.ownerId + \"2\", component: siliconOwner.popupComponent, initial: { parked: true, prewarm: true } });\n")],
    "sinoboard": [("modules/silicon/scene/SiliconScene.qml", "    BoardLayer {\n        id: board\n", "    BoardLayer {\n        id: board\n        visible: false\n")],
    "sinopatch": [("modules/silicon/scene/SiliconScene.qml", "        visible: !root.patchOff\n        cached: !root.pkgMoving\n",
                   "        visible: false\n        cached: !root.pkgMoving\n")],
    "sinocard": [("modules/silicon/scene/SiliconScene.qml", "        visible: root.cardPatchShown\n", "        visible: false\n")],
    "sinoglow": [("modules/silicon/scene/SiliconScene.qml", "    GlowLayer {\n        anchors.fill: parent\n", "    GlowLayer {\n        visible: false\n        anchors.fill: parent\n")],
    "sinofields": [("modules/silicon/scene/SiliconScene.qml", "    component Field: ParticleField {\n        anchors.fill: parent\n",
                    "    component Field: ParticleField {\n        enabled: false\n        opacity: 0\n        anchors.fill: parent\n")],
    "sinoholo": [("modules/silicon/scene/SiliconScene.qml", "    component Holo: HoloLayer {\n", "    component Holo: HoloLayer {\n        opacity: 0\n")],
    # FIRSTDRAW: the clock content's build, priced part by part (the clock is built synchronously in the warm-up: its entry's build=)
    "clkonetile": [("modules/clock/calendar/RowStrip.qml", "    readonly property int _range: 1\n", "    readonly property int _range: 0\n")],
    "clknorows": [("modules/clock/calendar/CalendarView.qml", "            id: stripRepeater\n            model: 6\n", "            id: stripRepeater\n            model: 0\n")],
    "clknotear": [("modules/clock/ClockPopupContent.qml", "                active: root.wiki !== null && root.wikiTearoffShown\n", "                active: false\n")],
    "clknolist": [("modules/clock/ClockPopupContent.qml", "                calendarData: root.calendarData\n                visibilityStore: visStore\n",
                   "                calendarData: null\n                visibilityStore: visStore\n")],
    "livetitle": [("modules/shell/ShellFrame.qml", "        sourceComponent: frame.services.mock ? windowMock : windowLive\n",
                   "        sourceComponent: frame.services.mock && Quickshell.env(\"SHELL_FOCUS\") !== \"live\" ? windowMock : windowLive\n")],
    # the bar window's visible region on whatever the run's shell.jsonc says (workarounds.visibleInk): the A/B of GooeyInk
    "visibleink": [("modules/shell/ShellConfig.qml", "    readonly property bool visibleInk: root.checked.workarounds.visibleInk === true\n",
                    "    readonly property bool visibleInk: true\n")],
    # the weather popup's view switch (`wview`), priced part by part
    "wvnomorph": [("modules/weather/WeatherPopup.qml", "    property int viewMorphMs: 210\n", "    property int viewMorphMs: 1\n")],
    "wvnofloat": [("modules/weather/WeatherPopup.qml", "    property bool cardFloat: true\n", "    property bool cardFloat: false\n")],
    "wvnolayers": [("modules/weather/WeatherPopup.qml", "    property bool staticLayers: true\n", "    property bool staticLayers: false\n")],
    "wvnobackdrop": [("modules/weather/WeatherPopup.qml", "    property bool backdropEnabled: true\n", "    property bool backdropEnabled: false\n")],
    "wvnopolys": [("modules/weather/WeatherHourlyStrip.qml", "    function _updatePolys() {\n", "    function _updatePolys() {\n        return;\n")],
    "hooktoggle": [(
        "modules/shell/ShellMain.qml",
        '            case "secret":',
        '            case "toggle": {\n'
        '                const fsOwner = shellServices.focusedOwner(arg);\n'
        '                if (!fsOwner || !fsOwner.toggle)\n'
        '                    return "none";\n'
        '                fsOwner.toggle();\n'
        '                return fsOwner.popupMine === true ? "open" : "shut";\n'
        '            }\n'
        '            case "wview": {\n'
        '                const fsW = shellServices.focusedOwner("weather");\n'
        '                const fsC = fsW && fsW.popupMine ? fsW.engine.thePopup.contentItem : null;\n'
        '                if (!fsC || !("viewMode" in fsC))\n'
        '                    return "none";\n'
        '                fsC.viewMode = arg;\n'
        '                return fsC.viewMode;\n'
        '            }\n'
        '            case "wikiopen":\n'
        '                shellServices.wiki.openRequested(arg);\n'
        '                return "asked";\n'
        '            case "secret":',
    )],
}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    tree = sys.argv[1]
    if os.path.exists(os.path.join(tree, ".git")):
        print(f"FS_ABLATE FAIL {tree} is a git work tree: a patch goes into a sandbox copy only")
        return 1
    plan, texts = [], {}
    for name in sys.argv[2:]:
        if name not in PATCHES:
            print(f"FS_ABLATE FAIL unknown patch {name} (known: {' '.join(sorted(PATCHES))})")
            return 1
        for path, old, new in PATCHES[name]:
            full = os.path.join(tree, path)
            text = texts[full] if full in texts else open(full).read()     # two patches of one file build on each other
            if text.count(old) != 1:
                print(f"FS_ABLATE FAIL {name}: the anchor matches {text.count(old)} times in {path}")
                return 1
            texts[full] = text.replace(old, new)
            plan.append((name, full))
    for full, text in texts.items():
        open(full, "w").write(text)
    for name, full in plan:
        print(f"FS_ABLATE ok {name} {os.path.relpath(full, tree)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
