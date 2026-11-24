pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/aerial/secondary"
import "modules/aerial/secondary/QrCode.js" as Qr

// =============================================================================
// aerial_qr_probe.qml -- renders the corpus (QR_CORPUS: a JSON list of { name, kind: "raw" | "wifi", text | { ssid, psk, security, hidden } })
// through the REAL QrView (the picture a phone would scan), one PNG per entry in OUT_DIR, and writes <name>.txt with the string that was
// encoded (the Wi-Fi ones are built by QrCode.js). tools/dev/aerial_qr_probe.sh then decodes every PNG with OpenCV and compares.
// Prints `AQR cell <name> v<version>` per entry and `AQR RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 420
        implicitHeight: 420
        visible: true
        color: "#808080"

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property string corpusPath: Quickshell.env("QR_CORPUS") || ""
        property var corpus: []
        property int step: -1
        property int fails: 0

        FileView {
            id: corpusFile
            path: win.corpusPath
            blockLoading: true
            printErrors: false
        }
        FileView {
            id: textOut
            blockWrites: true
            printErrors: false
            atomicWrites: false
        }

        Item {
            id: stage
            x: 10
            y: 10
            width: 400
            height: 400
            QrView {
                id: qr
                objectName: "qr"
                anchors.centerIn: parent
                maxSize: 330
            }
        }

        function textOf(e): string {
            if (e.kind === "wifi")
                return Qr.wifiString(e.text.ssid, e.text.psk, e.text.security, e.text.hidden);
            return e.text;
        }

        Component.onCompleted: {
            try {
                win.corpus = JSON.parse(corpusFile.text());
            } catch (e) {
                console.log("AQR FAIL corpus unreadable");
                win.fails++;
            }
        }

        Timer {
            interval: 160
            running: true
            repeat: true
            onTriggered: {
                if (win.outDir === "" || win.corpus.length === 0) {
                    stop();
                    console.log("AQR RESULT FAIL (no corpus / OUT_DIR)");
                    Qt.quit();
                    return;
                }
                if (win.step >= 0 && win.step < win.corpus.length) {
                    // the picture of the previous step is on screen: grab it
                    const e = win.corpus[win.step];
                    const nm = e.name;
                    const t = win.textOf(e);
                    stop();
                    stage.grabToImage(r => {
                        if (!r.saveToFile(win.outDir + "/" + nm + ".png"))
                            win.fails++;
                        textOut.path = win.outDir + "/" + nm + ".txt";
                        textOut.setText(t);
                        console.log("AQR cell " + nm + " v" + qr.version + " ok=" + qr.ok);
                        if (!qr.ok)
                            win.fails++;
                        win.step++;
                        win.next();
                        start();
                    });
                    return;
                }
                win.step = 0;
                win.next();
            }
        }
        function next(): void {
            if (win.step >= win.corpus.length) {
                console.log("AQR RESULT " + (win.fails === 0 ? "PASS" : "FAIL"));
                Qt.quit();
                return;
            }
            qr.text = win.textOf(win.corpus[win.step]);
        }
    }
}
