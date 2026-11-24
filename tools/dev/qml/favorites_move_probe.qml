pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "modules/common/components"

// favorites_move_probe -- FavoritesStore's move from the old place (legacyPath, the repo's root until 2026-11-23) to the state dir.
//   moved     only the old file: the new one appears with the same list, the old one is left byte for byte, the store holds the list
//   kept      both files: the new one wins, the old one is not read and not touched
//   toggle    a toggle after a move writes the NEW file only
//   none      no old file: no new file appears, the list is empty
// FAV_DIR is the runner's private directory (the runner seeds the files). Ends in "FAVM RESULT PASS|FAIL".
Window {
    id: win
    width: 100
    height: 100
    visible: true
    readonly property string dir: Quickshell.env("FAV_DIR") || ""
    property var stores: ({})
    property var checks: []

    Component {
        id: storeComp
        FavoritesStore {}
    }
    function make(name: string): void {
        win.stores[name] = storeComp.createObject(win, { path: win.dir + "/" + name + "/new/favorites.json", legacyPath: win.dir + "/" + name + "/old.json" });
    }
    function read(path: string): string {
        const x = new XMLHttpRequest();
        x.open("GET", "file://" + path, false);
        try {
            x.send();
        } catch (e) {
            return "";
        }
        return x.status === 0 || x.status === 200 ? x.responseText : "";
    }
    function check(name: string, ok: bool, why: string): void {
        win.checks.push({ name: name, ok: ok, why: why });
    }

    property int _t: 0
    Timer {
        id: tick
        interval: 100
        repeat: true
        running: win.dir !== ""
        onTriggered: {
            win._t++;
            if (win._t === 1) {
                ["moved", "kept", "none"].forEach(n => win.make(n));
                return;
            }
            if (win._t === 15) {
                const m = win.stores.moved, k = win.stores.kept, z = win.stores.none;
                const nm = win.read(win.dir + "/moved/new/favorites.json");
                win.check("moved: the new file holds the old list", nm.indexOf("\"yay\"") >= 0 && nm.indexOf("\"linux\"") >= 0, nm.replace(/\s+/g, " "));
                win.check("moved: the store holds it", JSON.stringify(m.favorites) === JSON.stringify(["yay", "linux"]), JSON.stringify(m.favorites));
                win.check("moved: the old file is untouched", win.read(win.dir + "/moved/old.json") === win.read(win.dir + "/moved/old.ref"), "differs");
                win.check("kept: the new file wins", JSON.stringify(k.favorites) === JSON.stringify(["mine"]), JSON.stringify(k.favorites));
                win.check("kept: the old file is untouched", win.read(win.dir + "/kept/old.json") === win.read(win.dir + "/kept/old.ref"), "differs");
                win.check("none: no file, no favourites", z.favorites.length === 0 && win.read(win.dir + "/none/new/favorites.json") === "", JSON.stringify(z.favorites));
                m.toggle("quickshell");
                return;
            }
            if (win._t === 25) {
                const nm = win.read(win.dir + "/moved/new/favorites.json");
                win.check("toggle: the new file takes it", nm.indexOf("\"quickshell\"") >= 0, nm.replace(/\s+/g, " "));
                win.check("toggle: the old file does not", win.read(win.dir + "/moved/old.json") === win.read(win.dir + "/moved/old.ref"), "differs");
                tick.stop();
                const bad = win.checks.filter(c => !c.ok).map(c => c.name);
                win.checks.forEach(c => console.log("FAVM " + (c.ok ? "ok  " : "FAIL") + " " + c.name + (c.ok ? "" : "  <" + c.why + ">")));
                console.log("FAVM RESULT " + (bad.length ? "FAIL (" + bad.join("; ") + ")" : "PASS (" + win.checks.length + " checks)"));
                Qt.quit();
            }
        }
    }
}
