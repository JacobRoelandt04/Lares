pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/gooey"

// tools/dev/qml/gooey_seam_shadow_probe.qml -- the shadow under the seam of a popup and its flush secondary (feedback/general.md
// "Secondary popup shadow issue at seam"; gooey_field.frag sminFaces): the real engine, a top bar, a 600 x 320 popup with a 300 px
// secondary at its end, the user's halo (ShellConfig's constants), grabbed at rest. CHILD_H: the secondary's height (320: the feet on
// one line; 200: its foot on the popup's, a concave corner at its top). OUT: the PNG; it prints the boxes the judge reads
// (tools/dev/gooey_seam_shadow_probe.sh): `SEAM box <x0> <x1> <foot> <seam>`. Smoked bare (no OUT) it quits at once.
Window {
    id: w
    width: 1400
    height: 640
    visible: true
    color: "#E4E7EE"
    readonly property int childH: Number(Quickshell.env("CHILD_H") || 320)
    readonly property string side: Quickshell.env("SIDE") || "end"

    GooeyEngine {
        id: eng
        anchors.fill: parent
        surfaceColor: Theme.surface
        barsList: [topBar]
        shadowReach: 28
        shadowStrength: 0.3
        shadowSpread: -20
        shadowSoftness: 0.6
        shadowBlend: 12
        shadowColor: Theme.shellShadow
        GooeyBar {
            id: topBar
            engine: eng
            barId: "top"
            edge: "top"
            rawPos: 0
            rawLen: eng.w
        }
    }
    Component {
        id: compMain
        Item {
            id: main
            implicitWidth: 600
            implicitHeight: 320
            property Component secondaryComponent: compChild
            property bool secondaryOpen: false
            property point secondaryAnchor: Qt.point(600, 160)
            property string secondarySide: w.side
            property real secondaryAnchorAt: w.childH < 320 ? 1 : 0.5
            property var secondaryKey: 1
        }
    }
    Component {
        id: compChild
        Item {
            implicitWidth: 300
            implicitHeight: w.childH
        }
    }
    property int step: 0
    Timer {
        interval: 0
        running: !Quickshell.env("OUT")
        onTriggered: Qt.quit()
    }
    Timer {
        interval: 200
        repeat: true
        running: !!Quickshell.env("OUT")
        onTriggered: {
            w.step++;
            if (w.step === 2)
                eng.open("seam", "top", 560, 600, 320, false, compMain);
            else if (w.step === 6 && eng.thePopup.contentItem) {
                const c = eng.thePopup.contentItem;
                // qmllint disable missing-property
                c.secondaryAnchor = Qt.point(600, w.childH < 320 ? 320 : 160);   // the content's own contract, not QQuickItem's
                c.secondaryOpen = true;
                // qmllint enable missing-property
            } else if (w.step === 14) {
                const P = eng.thePopup, C = eng.childPopup;
                const bp = P ? P.box : null, bc = C && C.live ? C.box : null;
                w.contentItem.grabToImage(r => {
                    r.saveToFile(Quickshell.env("OUT"));
                    if (bp && bc)
                        console.log("SEAM box " + Math.round(Math.min(bp.x0, bc.x0)) + " " + Math.round(Math.max(bp.x1, bc.x1)) + " "
                                    + Math.round(Math.max(bp.y1, bc.y1)) + " " + Math.round(bc.x0 > bp.x0 ? bc.x0 : bp.x0));
                    else
                        console.log("SEAM box none " + JSON.stringify([bp, bc]));
                    Qt.quit();
                });
            }
        }
    }
}
