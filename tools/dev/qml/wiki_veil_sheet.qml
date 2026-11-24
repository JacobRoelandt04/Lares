pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import "modules/common/theme"
import "modules/common/components"
import "modules/wiki"

// =============================================================================
// tools/dev/qml/wiki_veil_sheet.qml -- every wiki veil at the full card's well
// (424 x 238, in the well's carve) and as a thumbnail, one row per pattern, one
// column per article key. Runner: tools/dev/wiki_veil_sheet.sh.
//
//   WVS_OUT       the PNG
//   WVS_T         veil seconds after each article's start (default 0: the thumbnail's frame)
//   WVS_PATTERNS  a comma list of patterns (default: all)
//   WVS_KEYS      how many article columns (default 3)
//   WVS_PLATE     1: every well with the logo plate (no logo: the plate alone)
//   WVS_ZOOM      the picture magnified n times (nearest): for looking at lines
// A bare smoke (no WVS_OUT) quits at once.
// =============================================================================
Window {
    id: win
    visible: true
    color: Theme.surface
    width: stage.width * win.mag
    height: stage.height * win.mag

    readonly property string out: Quickshell.env("WVS_OUT") || ""
    readonly property real at: Number(Quickshell.env("WVS_T") || 0)
    readonly property int mag: Math.max(1, Number(Quickshell.env("WVS_ZOOM") || 1))
    readonly property bool plate: Quickshell.env("WVS_PLATE") === "1"
    readonly property var keys: ["wiki.archlinux.org/Systemd", "en.wikipedia.org/Messier_87", "wiki.gentoo.org/Portage",
                                 "docs.kernel.org/scheduler", "wiki.archlinux.org/PipeWire"].slice(0, Math.max(1, Number(Quickshell.env("WVS_KEYS") || 3)))
    readonly property var hues: ["mdBlue", "mdOrange", "mdTeal", "mdPurple", "mdGreen"]
    readonly property var names: {
        const want = (Quickshell.env("WVS_PATTERNS") || "").split(",").filter(s => s !== "");
        return want.length > 0 ? want : probe.patterns;
    }
    WikiVeil {
        id: probe
        visible: false
    }

    readonly property real wellW: 424
    readonly property real wellH: 238
    readonly property real thumb: 64
    readonly property real gap: 12

    Rectangle {
        id: stage
        width: win.gap + win.keys.length * (win.wellW + win.gap + win.thumb + win.gap)
        height: win.gap + win.names.length * (win.wellH + win.gap)
        color: Theme.surface
        scale: win.mag
        transformOrigin: Item.TopLeft
        smooth: false

        Repeater {
            model: win.names
            delegate: Item {
                id: row
                required property string modelData
                required property int index
                y: win.gap + row.index * (win.wellH + win.gap)
                Repeater {
                    model: win.keys
                    delegate: Item {
                        id: cell
                        required property string modelData
                        required property int index
                        x: win.gap + cell.index * (win.wellW + win.gap + win.thumb + win.gap)
                        width: win.wellW
                        height: win.wellH

                        WikiVeil {
                            id: big
                            anchors.fill: parent
                            seedKey: cell.modelData
                            pattern: row.modelData
                            hue: Theme[win.hues[cell.index % win.hues.length]]
                            running: false
                            cornerRadius: 14
                            plateRadius: win.plate ? Math.round(0.4 * win.wellH * big.style.plateFraction) : 0
                            Component.onCompleted: big.seek(win.at)
                        }
                        ShadowBox {
                            anchors.fill: parent
                            baseRadius: 14
                            surfaceColor: "transparent"
                            backgroundColor: "transparent"
                            bevelColor: Theme.bevel
                            shadowColor: Theme.border
                            bevelWidth: 1
                            shadowWidth: 3
                        }
                        Item {
                            x: win.wellW + win.gap
                            width: win.thumb
                            height: win.thumb
                            WikiVeil {
                                id: small
                                anchors.fill: parent
                                seedKey: cell.modelData
                                pattern: row.modelData
                                hue: Theme[win.hues[cell.index % win.hues.length]]
                                running: false
                                zoom: small.style.thumbZoom
                                cornerRadius: 8
                            }
                            ShadowBox {
                                anchors.fill: parent
                                baseRadius: 8
                                surfaceColor: "transparent"
                                backgroundColor: "transparent"
                                bevelColor: Theme.bevel
                                shadowColor: Theme.border
                                bevelWidth: 1
                                shadowWidth: 3
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        interval: win.out === "" ? 0 : 400
        running: true
        onTriggered: {
            if (win.out === "") {
                Qt.quit();
                return;
            }
            stage.grabToImage(r => {
                r.saveToFile(win.out);
                console.log("WVS saved " + win.out + " " + Math.round(stage.width) + "x" + Math.round(stage.height));
                Qt.quit();
            }, Qt.size(stage.width * win.mag, stage.height * win.mag));
        }
    }
}
