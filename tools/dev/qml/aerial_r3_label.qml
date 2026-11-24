pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/aerial/data"
import "modules/aerial/scene"
import "modules/aerial/scene/AerialFacts.js" as Facts
import "modules/common/theme"

// Round 3's label, for the eye (tools/dev/aerial_r3_label.sh): MODE -> $PNG, then quit.
//   flat    the label ALONE, flat, at 20 px per mm: every count of devices, docked / nothing / hotspot / long names, the drop hints, the chrome at four stages, both families
//   film    six stills of the wipe (the chrome 0.1 .. 1.0), Material over Blueprint
//   scene   the board scene on the mock's facts (SCEN=home|vpn|earbuds|hotspot|airplane, FAMILY=0|1, SCALE=1|1.35: the scene's width x SCALE, what the popup's own scale draws)
Window {
    id: win
    readonly property string mode: Quickshell.env("MODE") || "flat"
    readonly property real sc: Number(Quickshell.env("SCALE") || 1)
    readonly property int fam: Number(Quickshell.env("FAMILY") || 0)
    width: win.mode === "scene" ? Math.ceil(760 * win.sc) : 6 * 420 + 20
    height: win.mode === "scene" ? Math.ceil(640 * win.sc) : (win.mode === "film" ? 2 * 460 + 20 : 4 * 460 + 20)
    visible: true
    color: Theme.surface

    Rectangle { anchors.fill: parent; color: Theme.surface }       // (a grab holds the content, not the window's own colour)
    readonly property AerialStyle material: AerialStyle { family: 0 }
    readonly property AerialStyle bp: AerialStyle { family: 1 }

    readonly property var devs: [
        { address: "AA:01", name: "Earbuds", kind: "earbuds", battery: 74, parts: { left: 74, right: 80, case: 100, charging: false } },
        { address: "AA:02", name: "Headset X4", kind: "headset", battery: 45, parts: null },
        { address: "AA:03", name: "MX Master 3S", kind: "mouse", battery: 18, parts: null },
        { address: "AA:04", name: "Keychron K2 Pro", kind: "keyboard", battery: 90, parts: null },
        { address: "AA:05", name: "Pixel 8", kind: "phone", battery: -1, parts: null },
        { address: "AA:06", name: "Xbox Wireless Controller", kind: "gamepad", battery: 60, parts: null }
    ]
    function lab(o: var): var {
        return Object.assign({ docked: true, name: "Home-5G", lineA: "5 GHz · ch 36 · Wi-Fi 6", lineB: "-54 dBm · 1201 Mb/s", via: "", hint: false, vpn: false, bt: [] }, o || {});
    }
    readonly property var none: ({ docked: false, name: "", lineA: "", lineB: "", via: "", hint: true, vpn: false, bt: [] })
    readonly property var tun: ({ vpn: true, via: "via NL · NL#42" })
    readonly property var flat: [
        { t: "no device", f: 0, l: win.lab() },
        { t: "1 device, a long name", f: 0, l: win.lab({ name: "homenet-ABC12_5Ghz", bt: win.devs.slice(0, 1) }) },
        { t: "2 devices", f: 0, l: win.lab({ bt: win.devs.slice(0, 2) }) },
        { t: "3 devices", f: 0, l: win.lab({ bt: win.devs.slice(0, 3) }) },
        { t: "4 devices", f: 0, l: win.lab({ bt: win.devs.slice(0, 4) }) },
        { t: "6 devices", f: 0, l: win.lab({ bt: win.devs }) },
        { t: "nothing docked", f: 0, l: win.none },
        { t: "the hotspot", f: 0, l: win.lab({ name: "laptop-share", lineA: "hotspot · 5 GHz", lineB: "2 connected", bt: win.devs.slice(4, 5) }) },
        { t: "a longer name, no battery", f: 0, l: win.lab({ name: "Saved-Network-123456", bt: win.devs.slice(4, 5) }) },
        { t: "a name that must be cut", f: 0, l: win.lab({ name: "Hotel-Guest-Network-Floor-12-West_5GHz", bt: win.devs.slice(5, 6) }) },
        { t: "a network in the hand", f: 0, l: win.none, hint: "wifi" },
        { t: "a device in the hand", f: 0, l: win.lab({ bt: win.devs.slice(0, 1) }), hint: "bt" },
        { t: "chrome 0.35", f: 0, l: win.lab(win.tun), c: 0.35 },
        { t: "chrome 0.7", f: 0, l: win.lab(win.tun), c: 0.7 },
        { t: "chrome 1", f: 0, l: win.lab(win.tun), c: 1 },
        { t: "chrome 1, the glint", f: 0, l: win.lab(Object.assign({ bt: win.devs.slice(0, 1) }, win.tun)), c: 1, time: 0.62 },
        { t: "chrome 1, 2 devices", f: 0, l: win.lab(Object.assign({ bt: win.devs.slice(1, 3), name: "homenet-ABC12_5Ghz" }, win.tun)), c: 1 },
        { t: "chrome 1, 4 devices", f: 0, l: win.lab(Object.assign({ bt: win.devs.slice(0, 4) }, win.tun)), c: 1 },
        { t: "Blueprint, 1 device", f: 1, l: win.lab({ bt: win.devs.slice(0, 1) }) },
        { t: "Blueprint, nothing docked", f: 1, l: win.none },
        { t: "Blueprint, plate 0.35", f: 1, l: win.lab(win.tun), c: 0.35 },
        { t: "Blueprint, plate 0.7", f: 1, l: win.lab(win.tun), c: 0.7 },
        { t: "Blueprint, plate 1", f: 1, l: win.lab(win.tun), c: 1 },
        { t: "Blueprint, plate 1, 3 devices", f: 1, l: win.lab(Object.assign({ bt: win.devs.slice(0, 3) }, win.tun)), c: 1 }
    ]
    readonly property var film: [0.1, 0.28, 0.46, 0.64, 0.82, 1.0].map(c => ({ t: "wipe " + c, f: 0, l: win.lab(Object.assign({ bt: win.devs.slice(0, 1) }, win.tun)), c: c, time: 2.0 + c }))
        .concat([0.1, 0.28, 0.46, 0.64, 0.82, 1.0].map(c => ({ t: "Blueprint wipe " + c, f: 1, l: win.lab(Object.assign({ bt: win.devs.slice(0, 1) }, win.tun)), c: c, time: 2.0 + c })))

    Repeater {
        id: cells
        model: win.mode === "scene" ? [] : (win.mode === "film" ? win.film : win.flat)
        delegate: Item {
            id: cell
            required property var modelData
            required property int index
            readonly property AerialStyle st: cell.modelData.f === 1 ? win.bp : win.material
            x: 10 + (cell.index % 6) * 420
            y: 10 + Math.floor(cell.index / 6) * 460
            width: 420
            height: 460
            Text {
                text: cell.modelData.t
                color: Theme.textMuted
                font.pixelSize: 12
            }
            // (the card's shield round it, as the label lies on the card)
            Rectangle {
                x: -4
                y: 20
                width: lab.width + 8
                height: lab.height + 8
                radius: 6
                color: cell.modelData.f === 1 ? Theme.tokenOf("siliconBlueprintWash") : Theme.tokenOf("aerialShield")
            }
            AerialLabel {
                id: lab
                y: 24
                kPx: 20
                animate: false
                family: cell.modelData.f
                dark: Theme.mode === "dark"
                paper: cell.st.labelPaper
                ink: cell.st.labelInk
                etch: cell.st.labelEtch
                chromeSky: cell.st.chromeSky
                chromeBase: cell.st.chromeBase
                chromeDeep: cell.st.chromeDeep
                hot: cell.st.labelHot
                plateInk: cell.st.labelInk
                lip: cell.st.labelLip
                btHue: cell.st.btHue
                accent: cell.st.accent
                lowColour: cell.st.error
                label: cell.modelData.l
                hint: cell.modelData.hint || ""
                time: cell.modelData.time !== undefined ? cell.modelData.time : 3.0
                devPx: 0.05
            }
            function arm(): void {
                if (cell.modelData.c !== undefined)
                    lab.chrome = cell.modelData.c;
            }
        }
    }

    // ---- the scene on the mock's facts ----
    Loader {
        active: win.mode === "scene"
        sourceComponent: Item {
            width: win.width
            height: win.height
            AerialMock {
                id: mock
                live: true
                scenario: Quickshell.env("SCEN") || "home"
                drift: 0
                scanPeriodMs: 100000
                settleMs: 150
            }
            AerialScene {
                id: scene
                width: Math.ceil(760 * win.sc)
                family: win.fam
                renderScale: 1
                animate: false
                readonly property var facts: {
                    const dep = mock.serial;
                    return { wifi: mock.wifi, bt: mock.bt, wired: mock.wired, hotspot: mock.hotspot, proton: mock.proton, health: mock.health, rates: mock.rates, usage: mock.usage, speed: mock.speed, airplane: mock.airplane, config: mock.config, dep: dep };
                }
                state: Facts.describe(scene.facts, Date.now())
            }
        }
    }

    Timer {
        interval: win.mode === "scene" ? 2200 : 900
        running: true
        onTriggered: {
            for (let i = 0; i < cells.count; i++)
                cells.itemAt(i).arm();      // qmllint disable missing-property
            grab.start();
        }
    }
    Timer {
        id: grab
        interval: 400
        onTriggered: win.contentItem.grabToImage(r => { if (Quickshell.env("PNG")) r.saveToFile(Quickshell.env("PNG")); Qt.quit(); })
    }
}
