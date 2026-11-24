pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../common/components"
import "../common/components/JsonComments.js" as JsonComments
import "../common/flourish/FlourishConfig.js" as FlourishCfg
import "../common/config/ConfigCheck.js" as Check
import "../common/config/ConfigSpecs.js" as Specs
import "ShellLayout.js" as Layout
import "InputConfig.js" as InputCfg

// =============================================================================
// ShellConfig.qml -- the user's shell.jsonc (shell.json when there is no .jsonc), READ HOT.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/shell.jsonc (`configPath`, set once: a FileView is never
// repointed -- CLAUDE.md); ConfigFile reads the shell.jsonc beside it first, and the .json when there is none.
// Every key is optional; `config` is ShellLayout.merge() of the file over
// the defaults, so a missing file IS the defaults. .examples/shell.jsonc documents every key.
// `//` and `/* */` comments are allowed. A file that does not parse keeps the previous config (a typo
// in the middle of an edit must not rearrange the bar) and `lastError` names the line and column.
//
// WHAT IT HOLDS: the top bar's mode (islands | continuous), the island lengths per output (by
// connector name; "default" for the rest), the zone order, where notes and the LLM open. mockups/shell.qml's
// Layout tab edits the same object and writes the file (`write`), which this reads back: one source.
//
// THE LAYOUT'S CONSTANTS are no keys of the file: the spacing rule, the least void, the title's cap, the
// workspaces' groove, the joint's overrides and the halo's numbers are this item's property defaults below, tuned on
// mockups/shell.qml's Layout tab (Save writes them here) and handed to ShellLayout.merge with the file.
//
// `live: false` reads no file and `apply(obj)` merges an object over the defaults (a probe, a render).
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/shell.jsonc"

    // THE SPACING RULE, in px: the clear space between the INK of two neighbouring modules, and between the ink of an island's first
    // and last module and the island's edge (ShellLayout.INK says how much room each button leaves inside its own box). 0 .. 80.
    property int inkGap: 22
    // The least clear space between two islands (and between an island and a corner); lengths that would leave less are shortened --
    // the workspaces' groove first, then the window title's slot. 0 and up.
    property int minVoid: 12
    // The most the window title's slot takes (the left island follows the title up to this; a longer title fades out inside it). 120 and up.
    property int titleSlot: 340
    // The workspaces' groove: its drawing scale (0.4 .. 1; the clock's slot is 64 x 18 px at every scale), the pitch of its dots (px between
    // the two dots of one half, 24 .. 200) and its width (0 is fitted: 2 * pitch + 64 + 100 * scale; 100 and up wins).
    property real workspacesScale: 0.9
    property int workspacesPitch: 30
    property int workspacesWidth: 0
    // THE JOINT: the radius of the bars' joints is Hyprland's `decoration:rounding` + `general:border_size` (+ the shell's ring), asked of
    // Hyprland (HyprJoint). A number 0 .. 64 (compositor px) is used instead of Hyprland's for that one; below 0 asks.
    property real jointRounding: -1
    property real jointBorder: -1
    // THE HALO (shell.jsonc `"shadow": "halo"` turns it on, ShellLayout's THE SHELL'S EDGE): the band all round the shell's outline. Its
    // reach px past the edge (0 .. 96), its alpha at the edge (0 .. 1), the px the shape it falls from grows (-32 .. 32), how much of the
    // reach the fall takes (0.05 .. 1: 1 all of it, less keeps it dark near the edge), the px over which concave corners round off (0 .. 64).
    property real shadowReach: 28
    property real shadowStrength: 0.3
    property real shadowSpread: -20
    property real shadowSoftness: 0.6
    property real shadowBlend: 12

    // The merged config; never null. (The modules that are switched off stand in no zone: THE MODULES, below.)
    readonly property var config: Layout.merge(root._raw, root._consts, root.modulesOff)
    readonly property string lastError: root._lastError
    readonly property bool present: root._present
    // Bumps on every change of `config`.
    readonly property int serial: root._serial
    onConfigChanged: root._serial++
    // The parsed file itself (what the user wrote), {} when absent: the Layout tab edits this.
    readonly property var raw: root._raw
    // THE MODULES (`"modules": { "silicon": false }`, ShellLayout.MODULES): the ones that are switched off, id -> true. READ ONCE, as the shell
    // starts, and never again: a service is built or it is not (one that was taken away while its children run would take the shell with it,
    // ProcLane), and the bar must not show a button whose service is not there. `_raw` is {} at that moment (the file's first load arrives on
    // the event loop), so the candidates of ConfigFile are read here with blocking views of their own, from a binding: ShellServices' Loaders
    // take their answer in the turn they complete, before anything is built. A file that does not parse switches nothing off.
    readonly property var modulesOff: root.live ? root._startModules.off : Layout.modulesOf(root._raw ? root._raw.modules : undefined).off
    readonly property var _startPaths: JsonComments.configPaths(root.configPath)
    readonly property var _startModules: Layout.modulesOf(root._startRaw.modules)
    readonly property var _startRaw: {
        for (const v of [startJsonc, startJson, startOldJsonc, startOldJson]) {
            const t = v.path !== "" ? v.text() : "";
            if (t.trim().length === 0)
                continue;
            let obj = null;
            try {
                obj = JSON.parse(JsonComments.strip(t));
            } catch (e) {
                obj = null;
            }
            return obj && typeof obj === "object" && !Array.isArray(obj) ? obj : {};
        }
        return {};
    }
    component StartView: FileView {
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }
    StartView { id: startJsonc; path: root._startPaths.jsonc || "" }
    StartView { id: startJson; path: root._startPaths.json || "" }
    StartView { id: startOldJsonc; path: root._startPaths.oldJsonc || "" }
    StartView { id: startOldJson; path: root._startPaths.oldJson || "" }
    // ESCAPE WITH A DETAIL OPEN (GooeyEngine.escapeDetailFirst): `"escape": "detail"` puts the detail away first and closes the popup on
    // the next press; anything else ("all", the default, or no line) closes the popup with its detail at once. Hot, like the rest.
    readonly property bool escapeDetailFirst: !!root._raw && root._raw.escape === "detail"
    readonly property string _escapeProblem: !!root._raw && root._raw.escape !== undefined && root._raw.escape !== "all" && root._raw.escape !== "detail"
        ? "\"escape\" is " + JSON.stringify(root._raw.escape) + ", not \"all\" or \"detail\"" : ""
    on_EscapeProblemChanged: {
        if (root._escapeProblem !== "")
            console.warn("ShellConfig: shell.jsonc: " + root._escapeProblem + " -- one press closes all");
    }
    // THE TERMINAL the launcher runs a terminal app in, as a list; the app's own command is added at its end (`"terminal": ["kitty", "-e"]`).
    readonly property var terminal: {
        const t = root._raw ? root._raw.terminal : undefined;
        return t instanceof Array && t.length > 0 && t[0] !== "" && t.every(x => typeof x === "string") ? t : ["kitty", "-e"];
    }
    // THE POINTER OVER WHAT IT CAN ACT ON (ShellCursor, CursorCover): `"hoverCursor": true` lets it change (a hand, the beam, the resize
    // arrows); anything else ("false", the default, or no line) keeps the plain arrow everywhere. Hot, like the rest.
    readonly property bool hoverCursor: !!root._raw && root._raw.hoverCursor === true
    readonly property string _hoverCursorProblem: !!root._raw && root._raw.hoverCursor !== undefined && typeof root._raw.hoverCursor !== "boolean"
        ? "\"hoverCursor\" is " + JSON.stringify(root._raw.hoverCursor) + ", not true or false" : ""
    on_HoverCursorProblemChanged: {
        if (root._hoverCursorProblem !== "")
            console.warn("ShellConfig: shell.jsonc: " + root._hoverCursorProblem + " -- the pointer stays the arrow");
    }
    // THE MOUSE (InputConfig.js; WheelHub, SideSwipe, ScrollFeel): `"input": { ... }`. Hot, like the rest.
    readonly property var _inputParsed: InputCfg.parse(root._raw ? root._raw.input : undefined)
    readonly property var input: root._inputParsed.cfg
    readonly property string _inputProblem: root._inputParsed.problems.join("; ")
    on_InputProblemChanged: {
        if (root._inputProblem !== "")
            console.warn("ShellConfig: shell.jsonc: " + root._inputProblem + " -- the default is taken");
    }
    // THE AURA's switch (GooeyEngine.playAura; ShellServices.playAura asks): `"shadow": { "aura": true }`, false for anything else.
    readonly property bool auraEnabled: !!root._raw && !!root._raw.shadow && typeof root._raw.shadow === "object" && root._raw.shadow.aura === true
    // THE COLLECTION AT A SCREEN'S BUILD (ShellScreen's Component.onCompleted; CLAUDE.md "A GC CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD"):
    // `"workarounds": { "gcAtScreenBuild": false }` turns it off; on unless exactly false. Asked once per screen, as its window is built
    // -- which is BEFORE this config's first load has landed (`_raw` is still {} then: the file arrives on the event loop), so the answer
    // is read from the file itself (ConfigFile.textNow, a blocking read); a file that does not parse leaves it on.
    function gcAtScreenBuild(): bool {
        let raw = root._raw;
        if (root.live) {
            const r = root.parseText(fv.textNow());
            raw = r.parsed ? r.raw : null;
        }
        return !(!!raw && !!raw.workarounds && typeof raw.workarounds === "object" && raw.workarounds.gcAtScreenBuild === false);
    }
    // THE VISIBLE REGION OF THE INK (GooeyInk, ShellScreen): `"workarounds": { "visibleInk": true }` tells Hyprland where each bar window
    // can have ink, so it blends that and not the whole output under every frame of the shell. Off unless exactly true. Hot.
    readonly property bool visibleInk: root.checked.workarounds.visibleInk === true
    // THE OLED CARE'S SWITCH (docs/oledcare.md): `"oled": { "enabled": false }` stops the pixel shift (OledShift) and the random flourishes
    // (FlourishScheduler); on unless exactly false (FlourishConfig.enabledOf). Hot, like the rest.
    readonly property var oledSwitch: FlourishCfg.enabledOf(root._raw ? root._raw.oled : undefined)
    readonly property bool oledEnabled: root.oledSwitch.enabled
    onOledSwitchChanged: {
        if (root.oledSwitch.problem !== "")
            console.warn("ShellConfig: shell.jsonc: " + root.oledSwitch.problem + " -- it is on");
    }
    // THE RANDOM FLOURISHES (the OLED care; FlourishScheduler, docs/oledcare.md): `"oled": { "flourishes": { ... } }` checked,
    // a bad value its default (FlourishConfig.parse: { idle, active, idleEveryS, activeEveryS, glyphs, problems }). Hot, like the rest.
    readonly property var oledFlourishes: {
        const o = root._raw ? root._raw.oled : undefined;
        if (o !== undefined && o !== null && (typeof o !== "object" || Array.isArray(o)))
            return Object.assign(FlourishCfg.parse(undefined), { problems: ["oled must be an object"] });
        return FlourishCfg.parse(o ? o.flourishes : undefined);
    }
    onOledFlourishesChanged: {
        for (const p of root.oledFlourishes.problems)
            console.warn("ShellConfig: shell.jsonc: " + p + " -- its default is used");
    }
    // DICTATION (a prototype; modules/dictation/DictationService, docs/dictation.md): the file's `dictation` block as written, {}
    // when absent. Off unless its `enabled` is exactly true; DictationText.config() lays the defaults under it. Hot, like the rest.
    readonly property var dictation: !!root._raw && !!root._raw.dictation && typeof root._raw.dictation === "object"
        && !Array.isArray(root._raw.dictation) ? root._raw.dictation : ({})

    // THE THEME CURTAIN (a prototype; ThemeControl runs it): `"theme": { "curtain": true, "curtainStyle": "louvres" }`. Off unless
    // `curtain` is exactly true. `curtainStyle` is one of curtainStyles or "cycle" (the next one at every switch); a name that is not
    // one is "radial" and `curtainProblem` says so. `curtainLive` (a second prototype, off unless exactly true, and only with `curtain`): the
    // shell stays live through the transition and goes by the curtain's own line (ThemeWipe). Hot, like the rest of the file.
    readonly property var curtainStyles: ["radial", "peel", "louvres"]
    readonly property bool curtain: root._curtainPart.on
    readonly property bool curtainLive: root._curtainPart.on && root._curtainPart.live
    readonly property string curtainStyle: root._curtainPart.style
    readonly property string curtainProblem: root._curtainPart.problem
    // THE REPAINT UNDER THE CURTAIN (ThemeControl, tools/theme/hidden_repaint.py): while the curtain holds, every hidden workspace and
    // every hidden tab of a group is shown by turns, so no window comes back in the old colours later. On with the curtain unless
    // `"curtainRepaint": false`. A window stays on show its class's frames in `curtainRepaintClassFrames` (an object, window class ->
    // frames 1-60; the class exactly as `hyprctl clients` says it, in any case; kept here in lower case), else `curtainRepaintFrames`
    // (1-60, default 3). `curtainRepaintDebug`: the switch runs WITHOUT the curtain and the repaint is slowed to
    // `curtainRepaintDebugMs` a step (200-5000, default 900), each step named in a Hyprland notice -- to watch what the run does.
    readonly property bool curtainRepaint: root._curtainPart.on && root._curtainPart.repaint
    readonly property int curtainRepaintFrames: root._curtainPart.frames
    readonly property var curtainRepaintClassFrames: root._curtainPart.classFrames
    readonly property bool curtainRepaintDebug: root._curtainPart.on && root._curtainPart.repaint && root._curtainPart.debug
    readonly property int curtainRepaintDebugMs: root._curtainPart.debugMs
    readonly property var _curtainPart: {
        const t = root._raw ? root._raw.theme : undefined;
        if (t === undefined || t === null || typeof t !== "object" || Array.isArray(t))
            return { on: false, live: false, style: "radial", problem: "", repaint: true, frames: 3, classFrames: ({}), debug: false, debugMs: 900 };
        let problem = "";
        let style = "radial";
        if (t.curtainStyle !== undefined) {
            if (t.curtainStyle === "cycle" || root.curtainStyles.indexOf(t.curtainStyle) >= 0)
                style = t.curtainStyle;
            else
                problem = "shell.jsonc: theme.curtainStyle must be one of " + root.curtainStyles.join(", ") + " or \"cycle\", not " + JSON.stringify(t.curtainStyle);
        }
        if (t.curtain !== undefined && typeof t.curtain !== "boolean" && problem === "")
            problem = "shell.jsonc: theme.curtain must be true or false, not " + JSON.stringify(t.curtain);
        if (t.curtainLive !== undefined && typeof t.curtainLive !== "boolean" && problem === "")
            problem = "shell.jsonc: theme.curtainLive must be true or false, not " + JSON.stringify(t.curtainLive);
        if (t.curtainRepaint !== undefined && typeof t.curtainRepaint !== "boolean" && problem === "")
            problem = "shell.jsonc: theme.curtainRepaint must be true or false, not " + JSON.stringify(t.curtainRepaint);
        const num = (key, lo, hi, dflt) => {
            const v = t[key];
            if (v === undefined)
                return dflt;
            if (typeof v === "number" && v >= lo && v <= hi)
                return Math.round(v);
            if (problem === "")
                problem = "shell.jsonc: theme." + key + " must be a number from " + lo + " to " + hi + ", not " + JSON.stringify(v) + " (" + dflt + " is used)";
            return dflt;
        };
        const frames = num("curtainRepaintFrames", 1, 60, 3);
        const debugMs = num("curtainRepaintDebugMs", 200, 5000, 900);
        const classFrames = {};
        const cf = t.curtainRepaintClassFrames;
        if (cf !== undefined) {
            if (cf === null || typeof cf !== "object" || cf instanceof Array) {
                if (problem === "")
                    problem = "shell.jsonc: theme.curtainRepaintClassFrames must be an object of window class -> frames, like { \"zen\": 24 }";
            } else {
                for (const k of Object.keys(cf)) {
                    const v = cf[k];
                    if (k !== "" && typeof v === "number" && v >= 1 && v <= 60)
                        classFrames[k.toLowerCase()] = Math.round(v);
                    else if (problem === "")
                        problem = "shell.jsonc: theme.curtainRepaintClassFrames \"" + k + "\" must be a number from 1 to 60, not " + JSON.stringify(v) + " (" + frames + " is used)";
                }
            }
        }
        if (t.curtainRepaintDebug !== undefined && typeof t.curtainRepaintDebug !== "boolean" && problem === "")
            problem = "shell.jsonc: theme.curtainRepaintDebug must be true or false, not " + JSON.stringify(t.curtainRepaintDebug);
        return { on: t.curtain === true, live: t.curtainLive === true, style: style, problem: problem, repaint: t.curtainRepaint !== false, frames: frames,
                 classFrames: classFrames, debug: t.curtainRepaintDebug === true, debugMs: debugMs };
    }

    // THE FILE THROUGH ITS SPEC (modules/common/config/specs/shell.js): every key at what the file says, or at its default when it says nothing or
    // something wrong. The keys below are read from it; the ones above keep the readers they had. Right from the first turn: until the file's first
    // load has landed it is the file as it was read for `modules` (a screen's window is built before that load).
    readonly property var checked: Check.read(Specs.specOf("shell"), root.live && !root._landed ? root._startRaw : root._raw).settings
    // THE PIXEL SHIFT apart from the care's switch (OledShift), and its step.
    readonly property bool oledShift: root.oledEnabled && root.checked.oled.shift
    readonly property int oledShiftMs: Math.round(root.checked.oled.shiftEveryS * 1000)
    // THE AURA'S EVENTS (AuraEvents.events): { llm: seconds | false, update, timer, screencast }.
    readonly property var auraEvents: Check.isObject(root.checked.shadow) ? root.checked.shadow.auraEvents : Specs.specOf("shell").shadow[1].auraEvents
    // THE GLYPHS' FLOURISHES played by a hover, by a key (FlourishRegistry).
    readonly property bool flourishHover: root.checked.flourishes.hover
    readonly property bool flourishKey: root.checked.flourishes.key
    // What a right or middle click on a bar button does (ShellFrame.barClick), the popups a click outside closes, the displays that get the
    // bars (as text, so that a save that does not change it changes nothing), the programs that count as a screen share.
    readonly property var clicks: root.checked.clicks
    readonly property string clickAwayText: root.checked.clickAway.join(" ")
    readonly property string barsOutputsText: JSON.stringify(root.checked.bars.outputs)
    readonly property string recordersText: root.checked.recorders.join(" ")

    function reload(): void {
        if (root.live)
            fv.reload();
    }

    // A pure parse: { config, raw, error, parsed }.
    function parseText(txt: string): var {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { config: Layout.merge({}, root._consts), raw: {}, error: "", parsed: true };
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { config: null, raw: null, parsed: false,
                     error: (at ? "shell.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "shell.jsonc: " + e.message) + " -- the previous config is kept" };
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj))
            return { config: null, raw: null, parsed: false, error: "shell.jsonc: the top level is not an object -- the previous config is kept" };
        return { config: Layout.merge(obj, root._consts), raw: obj, error: "", parsed: true };
    }

    // Merge an object over the defaults (no file).
    function apply(obj: var): void {
        root._applied = true;
        root._raw = obj && typeof obj === "object" ? obj : {};
    }

    // Write the file (the Layout tab): the live reload then reads it back. Pretty, two spaces.
    function write(obj: var): void {
        if (!root.live) {
            root.apply(obj);
            return;
        }
        fv.setText(JSON.stringify(obj, null, 2) + "\n");
    }

    readonly property var _consts: ({
            inkGap: root.inkGap, minVoid: root.minVoid, titleSlot: root.titleSlot, workspacesScale: root.workspacesScale,
            workspacesPitch: root.workspacesPitch, workspacesWidth: root.workspacesWidth, jointRounding: root.jointRounding, jointBorder: root.jointBorder,
            shadowReach: root.shadowReach, shadowStrength: root.shadowStrength, shadowSpread: root.shadowSpread, shadowSoftness: root.shadowSoftness,
            shadowBlend: root.shadowBlend
        })
    property var _raw: ({})
    property string _lastError: ""
    property bool _present: false
    property int _serial: 0
    property string _text: ""
    property bool _applied: false
    // the file's own first load (or its absence) has been heard
    property bool _landed: false

    function _apply(txt: string, exists: bool): void {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._text && root._present === exists)
            return;
        root._applied = true;
        root._text = t;
        root._present = exists && t.length > 0;
        const r = root.parseText(root._present ? t : "");
        root._lastError = r.error;
        if (r.error.length > 0)
            console.warn("ShellConfig: " + r.error);
        if (!r.parsed)
            return;
        root._raw = r.raw;
    }

    // Always created (a FileView takes its path once and is never repointed); a not-live config
    // simply does not listen to it.
    ConfigFile {
        id: fv
        path: root.configPath
        watchChanges: root.live
        onLoaded: {
            if (!root.live)
                return;
            root._apply(fv.text(), true);
            root._landed = true;
        }
        onLoadFailed: {
            if (!root.live)
                return;
            root._apply("", false);
            root._landed = true;
        }
    }
    Component.onCompleted: {
        if (!root.live) {
            root._applied = true;
            return;
        }
        for (const p of root._startModules.problems)
            console.warn("ShellConfig: shell.jsonc: " + p);
        const t = fv.text();
        root._apply(t, t.length > 0);
    }
}
