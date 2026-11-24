pragma Singleton

import QtQuick
import Quickshell

import "ScaleConfig.js" as ScaleConfig

// =============================================================================
// ShellScale -- the shell's ONE scale (DeploymentNotes.md "Scaling").
//
// The user turns one number, `scale.global` in shell.jsonc: DEVICE pixels per DESIGN pixel. 1.25 makes the whole shell 25 %
// bigger, on any output, at whatever scale Hyprland itself gives that output -- the two are independent. The shell is laid
// out in DESIGN px and drawn magnified: ShellScreen puts the whole frame under one Item scale, `frameScale`, which is the
// configured number over the WINDOW's own pixel ratio, so a design px is `configured` device px on the glass.
//
//   configured(name, kind)    device px per design px for output `name`: kind "frame" (the global), "bar" or "popup"
//                             (the global x that kind's ratio); an output's own entry wins
//   dpr(item)                 the pixel ratio of the window `item` is in: `item.Window.window.devicePixelRatio`.
//                             NEVER `Screen.devicePixelRatio`: at a fractional Hyprland scale (1.25, 1.5) the attached
//                             Screen and the QScreen answer the INTEGER wl_output scale, 2
//   frameScale(item, name)    configured(name, "frame") / dpr(item): the Item scale of the frame inside one window
//   renderScale(name, kind)   = configured(name, kind): what a consumer multiplies a pixel size by to make a texture, a
//                             decode or a canvas at the glass's resolution (components that do not know their output read
//                             it with DeviceScale instead)
//   popupMap(name)           every popup's OWN ratio on the frame for output `name`: { ownerId: ratio } (shell.jsonc `scale.popups`; silicon 1.35
//                             unless the file says otherwise; "<id>.detail" keys are a popup's detail's); what the frame hands the engine (GooeyEngine.popupScales)
//   pillRatio(name, kind)     the ratio of one floating pill ("osd", "toast", "popup": shell.jsonc `scale.pills`), else the popups'
//   pillRender(name, kind)    device px per design px for it (the global x its ratio)
//   ratio(name, kind)         kind "bar" or "popup": the ratio on the frame (1 for "frame"): what ShellScreen hands its ShellFrame, which
//                             lays the bar out under it and hands the engine the popups' (GooeyEngine: THE RATIOS)
//
// WHERE THE NUMBERS COME FROM. `source` is ShellConfig's parsed shell.jsonc (ShellServices feeds it, hot: a change of the
// file is a change here); without it every scale is 1. The file's format and its validation are ScaleConfig.js's.
// =============================================================================
Singleton {
    id: root

    // The parsed shell.jsonc (ShellConfig.raw): the `scale` block is read from it.
    property var source: ({})
    readonly property var parsed: ScaleConfig.parse(root.source)

    function configured(name: string, kind: string): real {
        return ScaleConfig.configured(root.parsed, name, kind);
    }

    function dpr(item: Item): real {
        const w = item ? item.Window.window : null;
        return w && w.devicePixelRatio > 0 ? w.devicePixelRatio : 1;
    }

    function frameScale(item: Item, name: string): real {
        return root.configured(name, "frame") / root.dpr(item);
    }

    function renderScale(name: string, kind: string): real {
        return root.configured(name, kind);
    }

    function ratio(name: string, kind: string): real {
        return ScaleConfig.ratio(root.parsed, name, kind);
    }

    function popupMap(name: string): var {
        return ScaleConfig.popupMap(root.parsed, name);
    }

    function pillRatio(name: string, kind: string): real {
        return ScaleConfig.ratio(root.parsed, name, "pill:" + kind);
    }

    function pillRender(name: string, kind: string): real {
        return ScaleConfig.configured(root.parsed, name, "pill:" + kind);
    }
}
