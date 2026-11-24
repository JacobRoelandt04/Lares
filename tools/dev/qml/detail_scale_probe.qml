pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Every directory mockups/shell.qml takes types from (a file built by URL finds a directory's types only while a scanned file imports it).
import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/osd"
import "modules/shell"

// =============================================================================
// tools/dev/qml/detail_scale_probe.qml -- a popup's DETAIL has its own ratio (tools/dev/detail_scale_probe.sh; GooeyEngine: A POPUP'S OWN
// RATIO, GooeyBody.ownScale).
//
// The shell mockup (the real ShellFrame on its mock services, the config dir's shell.json read as the shell's) is built as a component
// -- the runner lays this file into the sandbox copy's mockups/ --, silicon is opened the way its button opens it and its tuning
// card out beside it. Prints one DSCALE line of the ratios and the boxes read off the engine and the two contents, and grabs the stage.
//
// Env: DS_OUT=<dir>  DS_TAG=<name>
// Prints: DSCALE <tag> pop=<popupRatio> map=<popupScales json> primary=<ratio> child=<ratio> pcontent=<w>x<h> ccontent=<w>x<h>
//   cbox=<w>x<h> (the child's drawn box, frame px) cdraw=<w>x<h> (its content as drawn, stage px) prs=<the primary content's renderScale>
//   crs=<the child content's> frs=<engine.frameRenderScale> dr=<engine.detailRatio("silicon")> drs=<engine.detailRenderScale("silicon")>
//   shell=<k>, then DSCALE <tag> DONE.
// =============================================================================
Scope {
    id: rig

    readonly property string out: Quickshell.env("DS_OUT") || ""
    readonly property string tag: Quickshell.env("DS_TAG") || "x"
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null
    property int _step: 0
    property int _settleWaits: 0

    Component.onCompleted: {
        if (rig.out === "") {
            console.log("DSCALE no DS_OUT: nothing to do");
            quitLater.start();
            return;
        }
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("DSCALE the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        tick.interval = 4000;
        tick.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        id: tick
        repeat: false
        onTriggered: rig.next()
    }
    function again(ms) {
        tick.interval = ms;
        tick.start();
    }
    function fmt(v) {
        return Number(v).toFixed(3);
    }
    function next() {
        const sv = rig.win && rig.win.frame ? rig.win.frame.services : null;
        if (rig._step === 0) {
            if (sv && sv.settled === false && rig._settleWaits++ < 120)
                return rig.again(500);
            rig.win.openOwner("silicon");
            rig._step = 1;
            return rig.again(2200);
        }
        if (rig._step === 1) {
            const it = rig.engine.thePopup.contentItem;
            if (!it || typeof it.openSecondary !== "function") {
                console.log("DSCALE " + rig.tag + " FAIL no silicon popup content (" + rig.engine.thePopup.phase + ")");
                return quitLater.start();
            }
            it.openSecondary("tuning");
            rig._step = 2;
            return rig.again(2200);
        }
        if (rig._step === 2) {
            rig.report();
            rig._step = 3;
            return rig.again(1500);
        }
        console.log("DSCALE " + rig.tag + " DONE");
        quitLater.start();
    }
    function report() {
        const E = rig.engine, P = E.thePopup, C = E.childPopup;
        const pi = P.contentItem, ci = C.contentItem;
        if (!pi || !ci || C.phase === "closed") {
            console.log("DSCALE " + rig.tag + " FAIL the secondary is not out (child phase " + C.phase + ")");
            return;
        }
        const scene = rig.win.sheetGrabItem;
        const d0 = ci.mapToItem(scene, 0, 0), d1 = ci.mapToItem(scene, ci.width, ci.height);
        const wh = (a, b) => rig.fmt(a) + "x" + rig.fmt(b);
        console.log("DSCALE " + rig.tag + " pop=" + rig.fmt(E.popupRatio) + " map=" + JSON.stringify(E.popupScales)
                    + " primary=" + rig.fmt(P.ratio) + " child=" + rig.fmt(C.ratio)
                    + " pcontent=" + wh(pi.implicitWidth, pi.implicitHeight) + " ccontent=" + wh(ci.implicitWidth, ci.implicitHeight)
                    + " cbox=" + wh(C.width, C.height) + " cdraw=" + wh(d1.x - d0.x, d1.y - d0.y)
                    + " prs=" + rig.fmt(pi.renderScale) + " crs=" + rig.fmt(ci.renderScale) + " frs=" + rig.fmt(E.frameRenderScale)
                    + " dr=" + (typeof E.detailRatio === "function" ? rig.fmt(E.detailRatio("silicon")) : "-")
                    + " drs=" + (typeof E.detailRenderScale === "function" ? rig.fmt(E.detailRenderScale("silicon/secondary")) : "-")
                    + " shell=" + rig.fmt(rig.win.shellScale));
        scene.grabToImage(r => {
            r.saveToFile(rig.out + "/" + rig.tag + ".png");
        });
    }
}
