pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import "modules/common/theme"
import "modules/picker"
import "modules/picker/data"

// picker_missing_probe.qml -- the picker's words when its data file is gone: the service says what happened and the popup shows it on its
// empty page. Run by tools/dev/picker_probe.sh in a sandbox copy whose modules/picker/data/picker_data.json it moved away first (PKM=1);
// smoked bare it quits. Prints `PKM ok|FAIL <what>` and `PKM RESULT PASS|FAIL (<n>/<n> checks)`.
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool on: Quickshell.env("PKM") === "1"
    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("PKM " + (ok ? "ok " : "FAIL ") + what);
    }
    PickerService {
        id: svc
        live: false
    }
    PickerStyle {
        id: sty
    }
    property bool built: false
    Window {
        visible: probe.on
        width: 600
        height: 420
        color: Theme.surface
        Loader {
            id: host
            anchors.fill: parent
            active: probe.built
            sourceComponent: Component {
                PickerPopup {
                    service: svc
                    // qmllint disable incompatible-type
                    style: sty
                    // qmllint enable incompatible-type
                    anchors.fill: parent
                }
            }
        }
    }
    function find(item: var, name: string): var {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.find(item.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    property int turns: 0
    Timer {
        interval: 50
        repeat: true
        running: probe.on
        onTriggered: {
            probe.turns++;
            if (!probe.built) {
                svc.ensureLoaded();
                probe.check(!svc.ready, "the data is gone in this copy");
                probe.check(svc.error === "The emoji and symbol data is missing or out of date: tools/picker/build_data.py makes it", "missing data: the service says what happened (" + JSON.stringify(svc.error) + ")");
                probe.built = true;
                return;
            }
            const e = host.item ? probe.find(host.item, "pickerEmpty") : null;
            if ((!e || e.text === "") && probe.turns < 100)
                return;
            probe.check(!!e && e.visible && e.text !== "" && e.text === svc.error, "missing data: the popup's empty page shows those words (" + (e ? JSON.stringify(e.text) : "no empty page") + ")");
            console.log("PKM RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
            Qt.quit();
        }
    }
    Timer {
        interval: 0
        running: !probe.on
        onTriggered: Qt.quit()
    }
}
