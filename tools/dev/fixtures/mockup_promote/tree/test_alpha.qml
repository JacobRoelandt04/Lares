import QtQuick
import "modules/common/mockup"
import "modules/common/components"
import "modules/alpha"
import "modules/gamma"
import "modules/battery"

// fixture: a mockup whose lists exercise every road a row can take
MockupWindow {
    id: win
    moduleId: "alpha"
    content: popup
    target: popup
    targets: ({
        boxAParams: popup.boxA,
        boxAColors: popup.boxA,
        boxAHex: popup.boxA,
        boxBParams: popup.boxB,
        partParams: popup.part,
        holderParams: popup.holder.inner,
        fieldParams: popup.field,
        styleParams: sty,
        knobs: tun,
        gammaParams: gamma,
        mockParams: gmock,
        batParams: bat,
        feelParams: FeelSingleton,
        themedColors: popup,
        jsonParams: popup,
        fileParams: popup
    })
    lists: ({
        popupParams: win.popupParams,
        boxAParams: win.boxAParams,
        boxAColors: win.boxAColors,
        boxAHex: win.boxAHex,
        boxBParams: win.boxBParams,
        partParams: win.partParams,
        holderParams: win.holderParams,
        fieldParams: win.fieldParams,
        styleParams: win.styleParams,
        knobs: win.knobs,
        gammaParams: win.gammaParams,
        mockParams: win.mockParams,
        batParams: win.batParams,
        feelParams: win.feelParams,
        themedColors: win.themedColors,
        jsonParams: win.jsonParams,
        fileParams: win.fileParams
    })
    themedLists: ["themedColors"]
    fileBackedLists: ({ fileParams: "alpha.json" })
    tabDefs: [{ name: "All", lists: ["popupParams", "boxAParams"] }]

    AlphaPopup {
        id: popup
        style: sty
    }
    GammaPopup {
        id: gamma
        pad: tun.padding
        fontFamily: tun.dress ? "Audiowide" : "Inter"
    }
    GammaMock {
        id: gmock
    }
    BatteryPopup {
        id: bat
    }
    SharedStyle {
        id: sty
    }
    QtObject {
        id: tun
        property real padding: 12
        property bool dress: false
        property real skipMe: 3
        property real sideIndex: 0
        property real titleSz: 16
    }

    readonly property var popupParams: [
        { label: "width", prop: "width0", group: "Popup", tip: "t", val: 120, from: 50, to: 300, step: 1 },
        { label: "face", prop: "fontFamily", group: "Popup", tip: "t", val: "Audiowide", kind: "text" },
        { label: "title", prop: "titleSize", group: "Popup", tip: "t", val: 16, from: 8, to: 40, step: 1 }
    ]
    readonly property var boxAParams: [
        { label: "gap", prop: "gap", group: "Box", tip: "t", val: 9, from: 0, to: 20, step: 1 },
        { label: "radius", prop: "radiusPx", group: "Box", tip: "t", val: 14, from: 0, to: 30, step: 1 },
        { label: "tints", prop: "tintCount", group: "Box", tip: "t", val: 2.5, from: 0, to: 9, step: 0.5 },
        { label: "bevel", prop: "bevel", group: "Box", tip: "t", val: false },
        { label: "label", prop: "label", group: "Box", tip: "t", val: "boxA", kind: "text" },
        { label: "ratio", prop: "ratio", group: "Box", tip: "t", val: 12, from: 0, to: 40, step: 1 },
        { label: "auto", prop: "auto", group: "Box", tip: "t", val: 5, from: -1, to: 20, step: 1 },
        { label: "fixed", prop: "fixed", group: "Box", tip: "t", val: 6, from: 0, to: 20, step: 1 },
        { label: "no default", prop: "noDefault", group: "Box", tip: "t", val: 3, from: 0, to: 20, step: 1 }
    ]
    readonly property var boxAColors: [
        { label: "accent", prop: "accent", group: "Colours", tip: "t", val: "@error" },
        { label: "fill", prop: "fill", group: "Colours", tip: "t", val: "#112233" }
    ]
    readonly property var boxAHex: [
        { label: "accent hex", prop: "accent", group: "Colours", tip: "t", val: "#123456" }
    ]
    readonly property var boxBParams: [
        { label: "gap", prop: "gap", group: "Box B", tip: "t", val: 8, from: 0, to: 20, step: 1 },
        { label: "label", prop: "label", group: "Box B", tip: "t", val: "second", kind: "text" }
    ]
    readonly property var partParams: [
        { label: "size", prop: "size", group: "Part", tip: "t", val: 12, from: 0, to: 40, step: 1 },
        { label: "thickness", prop: "thickness", group: "Part", tip: "t", val: 44, from: 0, to: 80, step: 1 },
        { label: "extent", prop: "extent", group: "Part", tip: "t", val: 10, from: 0, to: 80, step: 1 },
        { label: "face", prop: "face", group: "Part", tip: "t", val: "Audiowide", kind: "text" }
    ]
    readonly property var holderParams: [
        { label: "gap", prop: "gap", group: "Holder", tip: "t", val: 11, from: 0, to: 20, step: 1 }
    ]
    readonly property var fieldParams: [
        { label: "size", prop: "size", group: "Field", tip: "t", val: 6, from: 0, to: 40, step: 1 },
        { label: "thickness", prop: "thickness", group: "Field", tip: "t", val: 33, from: 0, to: 80, step: 1 }
    ]
    readonly property var styleParams: [
        { label: "tick", prop: "tick", group: "Style", tip: "t", val: 8, from: 0, to: 20, step: 1 },
        { label: "pitch", prop: "pitch", group: "Style", tip: "t", val: 36, from: 0, to: 80, step: 1 }
    ]
    readonly property var knobs: [
        { label: "padding", prop: "padding", group: "Knobs", tip: "t", val: 20, from: 0, to: 40, step: 1 },
        { label: "dress", prop: "dress", group: "Knobs", tip: "t", val: true },
        { label: "skip me", prop: "skipMe", group: "Knobs", tip: "t", val: 3, from: 0, to: 9, step: 1 },
        { label: "side", prop: "sideIndex", group: "Knobs", tip: "t", val: 1, choices: ["a", "b", "c"] },
        { label: "title", prop: "titleSz", group: "Knobs", tip: "t", val: 16, from: 8, to: 40, step: 1 }
    ]
    readonly property var gammaParams: [
        { label: "gap one", prop: "gapOne", group: "Gamma", tip: "t", val: 5, from: 0, to: 20, step: 1 }
    ]
    readonly property var mockParams: [
        { label: "pct", prop: "machinePct", group: "Mock", tip: "t", val: 55, from: 0, to: 100, step: 1 }
    ]
    readonly property var batParams: [
        { label: "face", prop: "fontFamily", group: "Bat", tip: "t", val: "Audiowide", kind: "text" },
        { label: "icon", prop: "iconSize", group: "Bat", tip: "t", val: 24, from: 8, to: 60, step: 1 }
    ]
    readonly property var feelParams: [
        { label: "speed", prop: "speed", group: "Feel", tip: "t", val: 1.5, from: 0.1, to: 4, step: 0.1 },
        { label: "notch", prop: "notchMs", group: "Feel", tip: "t", val: 140, from: 0, to: 400, step: 10 }
    ]
    readonly property var themedColors: [
        { label: "accent", prop: "accent", group: "Theme", tip: "t", val: "#4480F4" }
    ]
    readonly property var jsonParams: [
        { label: "rules", prop: "rules", group: "Json", tip: "t", val: "{\"a\":2,\"b\":[1,2]}", kind: "json", shape: "object" },
        { label: "rules text", prop: "rulesText", group: "Json", tip: "t", val: "{\"x\":1}", kind: "json", shape: "object" },
        { label: "side", prop: "side", group: "Json", tip: "t", val: 2, choices: ["far", "start", "end"] },
        { label: "weird", prop: "weird", group: "Json", tip: "t", val: 1, choices: ["a", "b"] },
        { label: "mode", prop: "mode", group: "Json", tip: "t", val: 1, choices: ["a", "b"] }
    ]
    readonly property var fileParams: [
        { label: "file knob", prop: "width0", group: "File", tip: "t", val: 130, from: 50, to: 300, step: 1 }
    ]
}
